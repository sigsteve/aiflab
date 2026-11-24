package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

var modelProbeGVK = schema.GroupVersionKind{
	Group:   "xtk.aiflab.io",
	Version: "v1alpha1",
	Kind:    "ModelProbe",
}

type modelProbeStatus struct {
	Healthy        bool               `json:"healthy"`
	LastStatusCode int64              `json:"lastStatusCode"`
	LatencyMS      int64              `json:"latencyMs"`
	LastProbeTime  metav1.Time        `json:"lastProbeTime"`
	Message        string             `json:"message"`
	Conditions     []metav1.Condition `json:"conditions"`
}

type modelProbeReconciler struct {
	client.Client
	httpClient *http.Client
}

func (r *modelProbeReconciler) Reconcile(
	ctx context.Context,
	request ctrl.Request,
) (ctrl.Result, error) {
	probe := &unstructured.Unstructured{}
	probe.SetGroupVersionKind(modelProbeGVK)

	if err := r.Get(ctx, request.NamespacedName, probe); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	interval, _, err := unstructured.NestedInt64(
		probe.Object,
		"spec",
		"intervalSeconds",
	)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("read intervalSeconds: %w", err)
	}
	if interval == 0 {
		interval = 30
	}

	expectedStatus, _, err := unstructured.NestedInt64(
		probe.Object,
		"spec",
		"expectStatus",
	)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("read expectStatus: %w", err)
	}
	if expectedStatus == 0 {
		expectedStatus = http.StatusOK
	}

	probeURL, _, err := unstructured.NestedString(probe.Object, "spec", "url")
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("read url: %w", err)
	}

	healthy, statusCode, latency, message := r.probe(ctx, probeURL, expectedStatus)
	now := metav1.Now()
	status := modelProbeStatus{}

	if rawStatus, found, nestedErr := unstructured.NestedMap(probe.Object, "status"); nestedErr != nil {
		return ctrl.Result{}, fmt.Errorf("read status: %w", nestedErr)
	} else if found {
		if conversionErr := runtime.DefaultUnstructuredConverter.FromUnstructured(
			rawStatus,
			&status,
		); conversionErr != nil {
			return ctrl.Result{}, fmt.Errorf("decode status: %w", conversionErr)
		}
	}

	status.Healthy = healthy
	status.LastStatusCode = statusCode
	status.LatencyMS = latency
	status.LastProbeTime = now
	status.Message = message

	conditionStatus := metav1.ConditionFalse
	reason := "ProbeFailed"
	if healthy {
		conditionStatus = metav1.ConditionTrue
		reason = "ProbeSucceeded"
	}
	meta.SetStatusCondition(&status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             conditionStatus,
		ObservedGeneration: probe.GetGeneration(),
		Reason:             reason,
		Message:            message,
	})

	rawStatus, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&status)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("encode status: %w", err)
	}
	probe.Object["status"] = rawStatus

	if err := r.Status().Update(ctx, probe); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("update status: %w", err)
	}

	return ctrl.Result{RequeueAfter: time.Duration(interval) * time.Second}, nil
}

func (r *modelProbeReconciler) probe(
	ctx context.Context,
	probeURL string,
	expectedStatus int64,
) (bool, int64, int64, string) {
	start := time.Now()
	parsedURL, err := url.ParseRequestURI(probeURL)
	if err != nil || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") {
		return false, 0, 0, "spec.url must be a valid http or https URL"
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, probeURL, nil)
	if err != nil {
		return false, 0, 0, err.Error()
	}

	response, err := r.httpClient.Do(request)
	latency := time.Since(start).Milliseconds()
	if err != nil {
		return false, 0, latency, err.Error()
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))

	statusCode := int64(response.StatusCode)
	healthy := statusCode == expectedStatus
	message := fmt.Sprintf(
		"received HTTP %d, expected HTTP %d",
		statusCode,
		expectedStatus,
	)

	return healthy, statusCode, latency, message
}

func main() {
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zap.Options{
		Development: false,
	})))

	manager, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 runtime.NewScheme(),
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: ":8081",
	})
	if err != nil {
		ctrl.Log.Error(err, "create manager")
		os.Exit(1)
	}

	resource := &unstructured.Unstructured{}
	resource.SetGroupVersionKind(modelProbeGVK)
	if err := ctrl.NewControllerManagedBy(manager).
		For(resource).
		WithEventFilter(predicate.GenerationChangedPredicate{}).
		Complete(&modelProbeReconciler{
			Client: manager.GetClient(),
			httpClient: &http.Client{
				Timeout: 5 * time.Second,
			},
		}); err != nil {
		ctrl.Log.Error(err, "create controller")
		os.Exit(1)
	}

	if err := manager.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "add health check")
		os.Exit(1)
	}
	if err := manager.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "add readiness check")
		os.Exit(1)
	}

	if err := manager.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "run manager")
		os.Exit(1)
	}
}
