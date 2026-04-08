package config

import (
	"fmt"
	"strings"

	"sigs.k8s.io/yaml"
)

type DeploymentConfig struct {
	Spec DeploymentConfigSpec `json:"spec" yaml:"spec"`
}

type DeploymentConfigSpec struct {
	DeploymentID  string                  `json:"deploymentId" yaml:"deploymentId"`
	EnvironmentID string                  `json:"environmentId" yaml:"environmentId"`
	DNS           DeploymentDNS           `json:"dns" yaml:"dns"`
	Certificates  DeploymentCertificates  `json:"certificates,omitempty" yaml:"certificates,omitempty"`
	IAM           *DeploymentIAM          `json:"iam,omitempty" yaml:"iam,omitempty"`
	Time          DeploymentTime          `json:"time" yaml:"time"`
	Network       DeploymentNetwork       `json:"network" yaml:"network"`
	Backup        DeploymentBackup        `json:"backup" yaml:"backup"`
	Observability DeploymentObservability `json:"observability" yaml:"observability"`
}

type DeploymentDNS struct {
	BaseDomain         string                  `json:"baseDomain" yaml:"baseDomain"`
	Hostnames          map[string]string       `json:"hostnames" yaml:"hostnames"`
	OperatorDNSServers []string                `json:"operatorDnsServers,omitempty" yaml:"operatorDnsServers,omitempty"`
	Authority          DeploymentDNSAuthority  `json:"authority,omitempty" yaml:"authority,omitempty"`
	Delegation         DeploymentDNSDelegation `json:"delegation,omitempty" yaml:"delegation,omitempty"`
	CloudDNS           DeploymentDNSCloudDNS   `json:"cloudDNS,omitempty" yaml:"cloudDNS,omitempty"`
}

type DeploymentDNSAuthority struct {
	NameServers []string `json:"nameServers,omitempty" yaml:"nameServers,omitempty"`
}

type DeploymentDNSDelegation struct {
	Mode       string                           `json:"mode,omitempty" yaml:"mode,omitempty"`
	ParentZone string                           `json:"parentZone,omitempty" yaml:"parentZone,omitempty"`
	WriterRef  DeploymentDNSDelegationWriterRef `json:"writerRef,omitempty" yaml:"writerRef,omitempty"`
}

type DeploymentDNSDelegationWriterRef struct {
	Name      string `json:"name,omitempty" yaml:"name,omitempty"`
	Namespace string `json:"namespace,omitempty" yaml:"namespace,omitempty"`
}

type DeploymentDNSCloudDNS struct {
	TenantWorkloadZones DeploymentDNSTenantWorkloadZones `json:"tenantWorkloadZones,omitempty" yaml:"tenantWorkloadZones,omitempty"`
}

type DeploymentDNSTenantWorkloadZones struct {
	Enabled    bool   `json:"enabled,omitempty" yaml:"enabled,omitempty"`
	ZoneSuffix string `json:"zoneSuffix,omitempty" yaml:"zoneSuffix,omitempty"`
}

type DeploymentCertificates struct {
	PlatformIngress DeploymentCertificatesSurface `json:"platformIngress,omitempty" yaml:"platformIngress,omitempty"`
	Tenants         DeploymentCertificatesSurface `json:"tenants,omitempty" yaml:"tenants,omitempty"`
	ACME            DeploymentCertificatesACME    `json:"acme,omitempty" yaml:"acme,omitempty"`
}

type DeploymentCertificatesSurface struct {
	Mode     string                      `json:"mode,omitempty" yaml:"mode,omitempty"`
	Wildcard DeploymentCertificatesBYOWC `json:"wildcard,omitempty" yaml:"wildcard,omitempty"`
}

type DeploymentCertificatesBYOWC struct {
	SecretName           string `json:"secretName,omitempty" yaml:"secretName,omitempty"`
	ExternalSecretName   string `json:"externalSecretName,omitempty" yaml:"externalSecretName,omitempty"`
	VaultPath            string `json:"vaultPath,omitempty" yaml:"vaultPath,omitempty"`
	TLSCertProperty      string `json:"tlsCertProperty,omitempty" yaml:"tlsCertProperty,omitempty"`
	TLSKeyProperty       string `json:"tlsKeyProperty,omitempty" yaml:"tlsKeyProperty,omitempty"`
	CABundleSecretName   string `json:"caBundleSecretName,omitempty" yaml:"caBundleSecretName,omitempty"`
	CABundleExternalName string `json:"caBundleExternalSecretName,omitempty" yaml:"caBundleExternalSecretName,omitempty"`
	CABundleVaultPath    string `json:"caBundleVaultPath,omitempty" yaml:"caBundleVaultPath,omitempty"`
	CABundleProperty     string `json:"caBundleProperty,omitempty" yaml:"caBundleProperty,omitempty"`
}

type DeploymentCertificatesACME struct {
	Server               string                           `json:"server,omitempty" yaml:"server,omitempty"`
	Email                string                           `json:"email,omitempty" yaml:"email,omitempty"`
	CABundle             string                           `json:"caBundle,omitempty" yaml:"caBundle,omitempty"`
	ClusterIssuerName    string                           `json:"clusterIssuerName,omitempty" yaml:"clusterIssuerName,omitempty"`
	PrivateKeySecretName string                           `json:"privateKeySecretName,omitempty" yaml:"privateKeySecretName,omitempty"`
	Solver               DeploymentCertificatesACMESolver `json:"solver,omitempty" yaml:"solver,omitempty"`
	Credentials          DeploymentCertificatesCredential `json:"credentials,omitempty" yaml:"credentials,omitempty"`
}

type DeploymentCertificatesACMESolver struct {
	Type       string                                     `json:"type,omitempty" yaml:"type,omitempty"`
	Provider   string                                     `json:"provider,omitempty" yaml:"provider,omitempty"`
	RFC2136    DeploymentCertificatesACMESolverRFC2136    `json:"rfc2136,omitempty" yaml:"rfc2136,omitempty"`
	Route53    DeploymentCertificatesACMESolverRoute53    `json:"route53,omitempty" yaml:"route53,omitempty"`
	Cloudflare DeploymentCertificatesACMESolverCloudflare `json:"cloudflare,omitempty" yaml:"cloudflare,omitempty"`
}

type DeploymentCertificatesACMESolverRFC2136 struct {
	NameServer    string `json:"nameServer,omitempty" yaml:"nameServer,omitempty"`
	TSIGKeyName   string `json:"tsigKeyName,omitempty" yaml:"tsigKeyName,omitempty"`
	TSIGAlgorithm string `json:"tsigAlgorithm,omitempty" yaml:"tsigAlgorithm,omitempty"`
}

type DeploymentCertificatesACMESolverRoute53 struct {
	Region       string `json:"region,omitempty" yaml:"region,omitempty"`
	HostedZoneID string `json:"hostedZoneID,omitempty" yaml:"hostedZoneID,omitempty"`
	Role         string `json:"role,omitempty" yaml:"role,omitempty"`
}

type DeploymentCertificatesACMESolverCloudflare struct {
	Email string `json:"email,omitempty" yaml:"email,omitempty"`
}

type DeploymentCertificatesCredential struct {
	SecretName                     string `json:"secretName,omitempty" yaml:"secretName,omitempty"`
	ExternalSecretName             string `json:"externalSecretName,omitempty" yaml:"externalSecretName,omitempty"`
	VaultPath                      string `json:"vaultPath,omitempty" yaml:"vaultPath,omitempty"`
	TSIGSecretProperty             string `json:"tsigSecretProperty,omitempty" yaml:"tsigSecretProperty,omitempty"`
	CloudflareAPITokenProperty     string `json:"cloudflareApiTokenProperty,omitempty" yaml:"cloudflareApiTokenProperty,omitempty"`
	Route53AccessKeyIDProperty     string `json:"route53AccessKeyIdProperty,omitempty" yaml:"route53AccessKeyIdProperty,omitempty"`
	Route53SecretAccessKeyProperty string `json:"route53SecretAccessKeyProperty,omitempty" yaml:"route53SecretAccessKeyProperty,omitempty"`
}

type DeploymentIAM struct {
	Mode            string                  `json:"mode,omitempty" yaml:"mode,omitempty"`
	PrimaryRealm    string                  `json:"primaryRealm,omitempty" yaml:"primaryRealm,omitempty"`
	SecondaryRealms []string                `json:"secondaryRealms,omitempty" yaml:"secondaryRealms,omitempty"`
	Upstream        DeploymentIAMUpstream   `json:"upstream,omitempty" yaml:"upstream,omitempty"`
	Hybrid          DeploymentIAMHybridMode `json:"hybrid,omitempty" yaml:"hybrid,omitempty"`
}

type DeploymentIAMUpstream struct {
	Type        string                   `json:"type,omitempty" yaml:"type,omitempty"`
	Alias       string                   `json:"alias,omitempty" yaml:"alias,omitempty"`
	DisplayName string                   `json:"displayName,omitempty" yaml:"displayName,omitempty"`
	OIDC        DeploymentIAMOIDC        `json:"oidc,omitempty" yaml:"oidc,omitempty"`
	SAML        DeploymentIAMSAML        `json:"saml,omitempty" yaml:"saml,omitempty"`
	LDAP        DeploymentIAMLDAP        `json:"ldap,omitempty" yaml:"ldap,omitempty"`
	SCIM        DeploymentIAMSCIM        `json:"scim,omitempty" yaml:"scim,omitempty"`
	Egress      DeploymentIAMEgressRules `json:"egress,omitempty" yaml:"egress,omitempty"`
}

type DeploymentIAMOIDC struct {
	IssuerURL       string                 `json:"issuerUrl,omitempty" yaml:"issuerUrl,omitempty"`
	ClientID        string                 `json:"clientId,omitempty" yaml:"clientId,omitempty"`
	ClientSecretRef DeploymentIAMValueRef  `json:"clientSecretRef,omitempty" yaml:"clientSecretRef,omitempty"`
	CARef           DeploymentIAMValueRef  `json:"caRef,omitempty" yaml:"caRef,omitempty"`
	GroupsClaim     string                 `json:"groupsClaim,omitempty" yaml:"groupsClaim,omitempty"`
	GroupMappings   []DeploymentIAMMapping `json:"groupMappings,omitempty" yaml:"groupMappings,omitempty"`
}

type DeploymentIAMSAML struct {
	EntityID        string                 `json:"entityId,omitempty" yaml:"entityId,omitempty"`
	SSOURL          string                 `json:"ssoUrl,omitempty" yaml:"ssoUrl,omitempty"`
	SigningCertRef  DeploymentIAMValueRef  `json:"signingCertRef,omitempty" yaml:"signingCertRef,omitempty"`
	GroupsAttribute string                 `json:"groupsAttribute,omitempty" yaml:"groupsAttribute,omitempty"`
	GroupMappings   []DeploymentIAMMapping `json:"groupMappings,omitempty" yaml:"groupMappings,omitempty"`
}

type DeploymentIAMLDAP struct {
	URL             string                `json:"url,omitempty" yaml:"url,omitempty"`
	StartTLS        bool                  `json:"startTls,omitempty" yaml:"startTls,omitempty"`
	BindDNRef       DeploymentIAMValueRef `json:"bindDnRef,omitempty" yaml:"bindDnRef,omitempty"`
	BindPasswordRef DeploymentIAMValueRef `json:"bindPasswordRef,omitempty" yaml:"bindPasswordRef,omitempty"`
	UsersBaseDN     string                `json:"usersBaseDn,omitempty" yaml:"usersBaseDn,omitempty"`
	GroupsBaseDN    string                `json:"groupsBaseDn,omitempty" yaml:"groupsBaseDn,omitempty"`
	UserFilter      string                `json:"userFilter,omitempty" yaml:"userFilter,omitempty"`
	GroupFilter     string                `json:"groupFilter,omitempty" yaml:"groupFilter,omitempty"`
	OperationMode   string                `json:"operationMode,omitempty" yaml:"operationMode,omitempty"`
}

type DeploymentIAMSCIM struct {
	Enabled   bool                  `json:"enabled,omitempty" yaml:"enabled,omitempty"`
	Direction string                `json:"direction,omitempty" yaml:"direction,omitempty"`
	AuthRef   DeploymentIAMValueRef `json:"authRef,omitempty" yaml:"authRef,omitempty"`
	BaseURL   string                `json:"baseUrl,omitempty" yaml:"baseUrl,omitempty"`
}

type DeploymentIAMHybridMode struct {
	HealthCheck       DeploymentIAMHealthCheck       `json:"healthCheck,omitempty" yaml:"healthCheck,omitempty"`
	OfflineCredential DeploymentIAMOfflineCredential `json:"offlineCredential,omitempty" yaml:"offlineCredential,omitempty"`
	FailOpen          *bool                          `json:"failOpen,omitempty" yaml:"failOpen,omitempty"`
}

type DeploymentIAMHealthCheck struct {
	Type             string                `json:"type,omitempty" yaml:"type,omitempty"`
	URL              string                `json:"url,omitempty" yaml:"url,omitempty"`
	Host             string                `json:"host,omitempty" yaml:"host,omitempty"`
	Port             int                   `json:"port,omitempty" yaml:"port,omitempty"`
	CARef            DeploymentIAMValueRef `json:"caRef,omitempty" yaml:"caRef,omitempty"`
	TimeoutSeconds   int                   `json:"timeoutSeconds,omitempty" yaml:"timeoutSeconds,omitempty"`
	IntervalSeconds  int                   `json:"intervalSeconds,omitempty" yaml:"intervalSeconds,omitempty"`
	SuccessThreshold int                   `json:"successThreshold,omitempty" yaml:"successThreshold,omitempty"`
	FailureThreshold int                   `json:"failureThreshold,omitempty" yaml:"failureThreshold,omitempty"`
}

type DeploymentIAMOfflineCredential struct {
	Required bool   `json:"required,omitempty" yaml:"required,omitempty"`
	Method   string `json:"method,omitempty" yaml:"method,omitempty"`
}

type DeploymentIAMEgressRules struct {
	AllowedCIDRs []string `json:"allowedCidrs,omitempty" yaml:"allowedCidrs,omitempty"`
	Ports        []int    `json:"ports,omitempty" yaml:"ports,omitempty"`
}

type DeploymentIAMValueRef struct {
	SecretName string `json:"secretName,omitempty" yaml:"secretName,omitempty"`
	SecretKey  string `json:"secretKey,omitempty" yaml:"secretKey,omitempty"`
	Namespace  string `json:"namespace,omitempty" yaml:"namespace,omitempty"`
	VaultPath  string `json:"vaultPath,omitempty" yaml:"vaultPath,omitempty"`
	VaultKey   string `json:"vaultKey,omitempty" yaml:"vaultKey,omitempty"`
}

type DeploymentIAMMapping struct {
	Source string `json:"source,omitempty" yaml:"source,omitempty"`
	Target string `json:"target,omitempty" yaml:"target,omitempty"`
}

type DeploymentTime struct {
	NTP DeploymentTimeNTP `json:"ntp" yaml:"ntp"`
}

type DeploymentTimeNTP struct {
	UpstreamServers []string `json:"upstreamServers" yaml:"upstreamServers"`
}

type DeploymentNetwork struct {
	VIP DeploymentVIP `json:"vip" yaml:"vip"`
}

type DeploymentVIP struct {
	PublicGatewayIP string `json:"publicGatewayIP" yaml:"publicGatewayIP"`
	PowerDNSIP      string `json:"powerdnsIP" yaml:"powerdnsIP"`
}

type DeploymentBackup struct {
	Enabled   bool                      `json:"enabled" yaml:"enabled"`
	Target    DeploymentBackupTarget    `json:"target" yaml:"target"`
	RPO       DeploymentBackupRPO       `json:"rpo" yaml:"rpo"`
	Retention DeploymentBackupRetention `json:"retention" yaml:"retention"`
	Schedules DeploymentBackupSchedules `json:"schedules" yaml:"schedules"`
}

type DeploymentBackupTarget struct {
	Type string              `json:"type" yaml:"type"`
	NFS  DeploymentBackupNFS `json:"nfs" yaml:"nfs"`
}

type DeploymentBackupNFS struct {
	Server       string   `json:"server" yaml:"server"`
	ExportPath   string   `json:"exportPath" yaml:"exportPath"`
	MountOptions []string `json:"mountOptions" yaml:"mountOptions"`
}

type DeploymentBackupRPO struct {
	Tier0    string `json:"tier0" yaml:"tier0"`
	S3Mirror string `json:"s3Mirror" yaml:"s3Mirror"`
	PVC      string `json:"pvc" yaml:"pvc"`
}

type DeploymentBackupRetention struct {
	Restic string                         `json:"restic" yaml:"restic"`
	Tier0  DeploymentBackupTier0Retention `json:"tier0" yaml:"tier0"`
}

type DeploymentBackupTier0Retention struct {
	HourlyWithin string `json:"hourlyWithin" yaml:"hourlyWithin"`
	DailyWithin  string `json:"dailyWithin" yaml:"dailyWithin"`
	TotalWithin  string `json:"totalWithin" yaml:"totalWithin"`
}

type DeploymentBackupSchedules struct {
	S3Mirror                  string `json:"s3Mirror" yaml:"s3Mirror"`
	SmokeBackupTargetWrite    string `json:"smokeBackupTargetWrite" yaml:"smokeBackupTargetWrite"`
	SmokeBackupsFreshness     string `json:"smokeBackupsFreshness" yaml:"smokeBackupsFreshness"`
	BackupSetAssemble         string `json:"backupSetAssemble" yaml:"backupSetAssemble"`
	PVCResticBackup           string `json:"pvcResticBackup" yaml:"pvcResticBackup"`
	SmokePVCResticCredentials string `json:"smokePvcResticCredentials" yaml:"smokePvcResticCredentials"`
	PruneTier0                string `json:"pruneTier0" yaml:"pruneTier0"`
	SmokeFullRestoreStaleness string `json:"smokeFullRestoreStaleness" yaml:"smokeFullRestoreStaleness"`
}

type DeploymentObservability struct {
	Loki DeploymentLoki `json:"loki" yaml:"loki"`
}

type DeploymentLoki struct {
	Limits LokiLimits `json:"limits" yaml:"limits"`
}

type LokiLimits struct {
	RetentionPeriod         string `json:"retentionPeriod" yaml:"retentionPeriod"`
	IngestionRateMb         *int   `json:"ingestionRateMb,omitempty" yaml:"ingestionRateMb,omitempty"`
	IngestionBurstSizeMb    *int   `json:"ingestionBurstSizeMb,omitempty" yaml:"ingestionBurstSizeMb,omitempty"`
	MaxGlobalStreamsPerUser *int   `json:"maxGlobalStreamsPerUser,omitempty" yaml:"maxGlobalStreamsPerUser,omitempty"`
}

func (s DeploymentConfigSpec) PlatformIngressCertificatesMode() string {
	mode := strings.TrimSpace(s.Certificates.PlatformIngress.Mode)
	if mode == "" {
		return "subCa"
	}
	return mode
}

func (s DeploymentConfigSpec) TenantCertificatesMode() string {
	mode := strings.TrimSpace(s.Certificates.Tenants.Mode)
	if mode == "" {
		return "subCa"
	}
	return mode
}

func (s DeploymentConfigSpec) ACMEClusterIssuerName() string {
	name := strings.TrimSpace(s.Certificates.ACME.ClusterIssuerName)
	if name == "" {
		return "acme"
	}
	return name
}

func (s DeploymentConfigSpec) ACMESolverType() string {
	solverType := strings.TrimSpace(s.Certificates.ACME.Solver.Type)
	if solverType == "" {
		return "dns01"
	}
	return solverType
}

func (s DeploymentConfigSpec) ACMESolverProvider() string {
	provider := strings.TrimSpace(s.Certificates.ACME.Solver.Provider)
	if provider == "" {
		return "rfc2136"
	}
	return provider
}

func (s DeploymentConfigSpec) ACMEPrivateKeySecretName() string {
	name := strings.TrimSpace(s.Certificates.ACME.PrivateKeySecretName)
	if name == "" {
		return "acme-account-key"
	}
	return name
}

func (s DeploymentConfigSpec) ACMECredentialsSecretName() string {
	name := strings.TrimSpace(s.Certificates.ACME.Credentials.SecretName)
	if name == "" {
		return "cert-manager-acme-dns01-credentials"
	}
	return name
}

func (s DeploymentConfigSpec) ACMECredentialsExternalSecretName() string {
	name := strings.TrimSpace(s.Certificates.ACME.Credentials.ExternalSecretName)
	if name == "" {
		return "cert-manager-acme-dns01-credentials"
	}
	return name
}

func (s DeploymentConfigSpec) ACMETSIGSecretProperty() string {
	prop := strings.TrimSpace(s.Certificates.ACME.Credentials.TSIGSecretProperty)
	if prop == "" {
		return "tsigSecret"
	}
	return prop
}

func (s DeploymentConfigSpec) ACMECloudflareAPITokenProperty() string {
	prop := strings.TrimSpace(s.Certificates.ACME.Credentials.CloudflareAPITokenProperty)
	if prop == "" {
		return "apiToken"
	}
	return prop
}

func (s DeploymentConfigSpec) ACMERoute53AccessKeyIDProperty() string {
	prop := strings.TrimSpace(s.Certificates.ACME.Credentials.Route53AccessKeyIDProperty)
	if prop == "" {
		return "accessKeyID"
	}
	return prop
}

func (s DeploymentConfigSpec) ACMERoute53SecretAccessKeyProperty() string {
	prop := strings.TrimSpace(s.Certificates.ACME.Credentials.Route53SecretAccessKeyProperty)
	if prop == "" {
		return "secretAccessKey"
	}
	return prop
}

func (s DeploymentConfigSpec) PlatformWildcardSecretName() string {
	name := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.SecretName)
	if name == "" {
		return "platform-wildcard-tls"
	}
	return name
}

func (s DeploymentConfigSpec) PlatformWildcardExternalSecretName() string {
	name := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.ExternalSecretName)
	if name == "" {
		return "platform-wildcard-tls"
	}
	return name
}

func (s DeploymentConfigSpec) PlatformWildcardTLSCertProperty() string {
	prop := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.TLSCertProperty)
	if prop == "" {
		return "tls.crt"
	}
	return prop
}

func (s DeploymentConfigSpec) PlatformWildcardTLSKeyProperty() string {
	prop := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.TLSKeyProperty)
	if prop == "" {
		return "tls.key"
	}
	return prop
}

func (s DeploymentConfigSpec) PlatformWildcardCABundleSecretName() string {
	name := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.CABundleSecretName)
	if name == "" {
		return "platform-wildcard-ca"
	}
	return name
}

func (s DeploymentConfigSpec) PlatformWildcardCABundleExternalSecretName() string {
	name := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.CABundleExternalName)
	if name == "" {
		return "platform-wildcard-ca"
	}
	return name
}

func (s DeploymentConfigSpec) PlatformWildcardCABundleProperty() string {
	prop := strings.TrimSpace(s.Certificates.PlatformIngress.Wildcard.CABundleProperty)
	if prop == "" {
		return "ca.crt"
	}
	return prop
}

func ParseDeploymentConfig(raw []byte) (*DeploymentConfig, error) {
	var cfg DeploymentConfig
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse DeploymentConfig: %w", err)
	}
	return &cfg, nil
}
