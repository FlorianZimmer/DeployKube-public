package controllers

type DeploymentConfigSource struct {
	Namespace string
	Name      string
	Key       string
}

type DeploymentConfigSnapshotConfig struct {
	Name       string
	Key        string
	Namespaces []string
}

type GatewayTargets struct {
	Namespace         string
	PublicGatewayName string
}

type ForgejoTargets struct {
	BaseURL           string
	CASecretNamespace string
	CASecretName      string
	CASecretKey       string
}

type Config struct {
	DeploymentConfig         DeploymentConfigSource
	DeploymentConfigSnapshot DeploymentConfigSnapshotConfig
	Gateways                 GatewayTargets
	Forgejo                  ForgejoTargets
	BackupSystemWiring       BackupSystemWiringConfig
	EgressProxy              EgressProxyConfig
	IngressCerts             IngressCertsConfig
	IngressAdjacent          IngressAdjacentConfig
	LokiLimits               LokiLimitsConfig
	DNSWiring                DNSWiringConfig
	CloudDNS                 CloudDNSConfig
	KeycloakUpstreamEgress   KeycloakUpstreamEgressConfig
	PlatformApps             PlatformAppsConfig
	Postgres                 PostgresConfig
}

type BackupSystemWiringConfig struct {
	ObserveOnly bool
}

type EgressProxyConfig struct {
	ObserveOnly bool
}

type IngressCertsConfig struct {
	ObserveOnly bool
}

type IngressAdjacentConfig struct {
	ObserveOnly bool
}

type LokiLimitsConfig struct {
	ObserveOnly bool
}

type DNSWiringConfig struct {
	ObserveOnly bool
}

type CloudDNSConfig struct {
	ObserveOnly bool
}

type KeycloakUpstreamEgressConfig struct {
	ObserveOnly bool
}

type PlatformAppsConfig struct {
	ObserveOnly bool
}

type PostgresConfig struct {
	ObserveOnly bool
}
