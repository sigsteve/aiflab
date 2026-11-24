# ModelProbe extension

This extension installs a ModelProbe custom resource, its controller, sample probes, and a live AI Factory page.

For a cluster on this machine, run `make deploy`. The script builds the controller with Docker or Podman and loads it with RKE2.

For a remote cluster, set `MODELPROBE_IMAGE` to a registry path that you can push and the cluster can pull. Then run `make deploy`.

Run `make undeploy` to remove the extension, controller, samples, and custom resource definition.
