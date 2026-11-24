export type ExtensionId = string & { readonly __brand: 'ExtensionId' };
export type PageSlug = string & { readonly __brand: 'PageSlug' };

export type PageAccessRule =
  | { readonly kind: 'always' }
  | {
    readonly kind: 'resource';
    readonly resourceType: string;
    readonly verb?: 'GET' | 'LIST' | 'CREATE' | 'UPDATE' | 'DELETE' | 'WATCH';
  }
  | { readonly kind: 'feature'; readonly feature: string };

export interface AifExtensionPage {
  readonly slug: string;
  readonly label: string;
  readonly component: unknown;
  readonly weight?: number;
  readonly access?: PageAccessRule;
  readonly icon?: string;
}

export interface AifExtensionDefinition {
  readonly id: string;
  readonly group?: string;
  readonly pages: readonly AifExtensionPage[];
}

export interface ResolvedPageRegistration {
  readonly virtualTypeName: string;
  readonly routeName: string;
  readonly routePath: string;
  readonly label: string;
  readonly group: string;
  readonly weight?: number;
  readonly access: PageAccessRule;
  readonly component: unknown;
  readonly icon?: string;
}

export interface ParsedAifExtensionPage
  extends Omit<AifExtensionPage, 'slug'> {
  readonly slug: PageSlug;
}

export interface ParsedAifExtensionDefinition
  extends Omit<AifExtensionDefinition, 'id' | 'pages'> {
  readonly id: ExtensionId;
  readonly pages: readonly ParsedAifExtensionPage[];
}

export interface RancherRoute {
  readonly name: string;
  readonly path: string;
  readonly component: unknown;
  readonly meta: {
    readonly product: 'suseai';
  };
}

interface RancherVirtualTypeBase {
  readonly name: string;
  readonly label: string;
  readonly route: {
    readonly name: string;
  };
  readonly icon?: string;
}

export type RancherVirtualType =
  | (RancherVirtualTypeBase & {
    readonly ifFeature?: never;
    readonly ifHaveType?: never;
    readonly ifHaveVerb?: never;
  })
  | (RancherVirtualTypeBase & {
    readonly ifFeature?: never;
    readonly ifHaveType: string;
    readonly ifHaveVerb?: string;
  })
  | (RancherVirtualTypeBase & {
    readonly ifFeature: string;
    readonly ifHaveType?: never;
    readonly ifHaveVerb?: never;
  });

export interface RancherDsl {
  virtualType(definition: RancherVirtualType): void;
  basicType(typeNames: readonly string[], group: string): void;
  weightType(
    label: string,
    weight: number,
    forBasic: true,
  ): void;
}

export interface RancherProductRegistration {
  readonly init: ($plugin: RancherPlugin, store: unknown) => void;
}

export interface RancherPlugin {
  addProduct(registration: RancherProductRegistration): void;
  addRoutes(routes: readonly RancherRoute[]): void;
  DSL(store: unknown, productName: 'suseai'): RancherDsl;
}
