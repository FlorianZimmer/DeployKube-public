package main

import (
	"flag"
	"os"
	"strings"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	gatewayv1 "sigs.k8s.io/gateway-api/apis/v1"

	datav1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/data/v1alpha1"
	tenancyv1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/tenancy/v1alpha1"
	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/controllers"
)

func main() {
	var deploymentConfigNamespace string
	var deploymentConfigName string
	var deploymentConfigKey string
	var snapshotName string
	var snapshotKey string
	var snapshotNamespacesCSV string
	var gatewayNamespace string
	var publicGatewayName string
	var forgejoBaseURL string
	var forgejoCASecretNamespace string
	var forgejoCASecretName string
	var forgejoCASecretKey string
	var controllerProfile string
	var backupSystemWiringObserveOnly bool
	var egressProxyObserveOnly bool
	var ingressCertsObserveOnly bool
	var ingressAdjacentObserveOnly bool
	var lokiLimitsObserveOnly bool
	var dnsWiringObserveOnly bool
	var cloudDNSObserveOnly bool
	var keycloakUpstreamEgressObserveOnly bool
	var platformAppsObserveOnly bool
	var postgresObserveOnly bool

	var metricsAddr string
	var probeAddr string
	var enableLeaderElection bool
	var leaderElectionID string

	flag.StringVar(&deploymentConfigNamespace, "deployment-config-namespace", "argocd", "Namespace containing ConfigMap/deploykube-deployment-config")
	flag.StringVar(&deploymentConfigName, "deployment-config-name", "deploykube-deployment-config", "Name of the DeploymentConfig ConfigMap")
	flag.StringVar(&deploymentConfigKey, "deployment-config-key", "deployment-config.yaml", "Key in the DeploymentConfig ConfigMap data")
	flag.StringVar(&snapshotName, "snapshot-name", "deploykube-deployment-config", "Name of the DeploymentConfig snapshot ConfigMap")
	flag.StringVar(&snapshotKey, "snapshot-key", "deployment-config.yaml", "Key in the DeploymentConfig snapshot ConfigMap data")
	flag.StringVar(&snapshotNamespacesCSV, "snapshot-namespaces", "argocd", "Comma-separated list of namespaces that should get a DeploymentConfig snapshot ConfigMap (for Job/CronJob consumers)")
	flag.StringVar(&gatewayNamespace, "gateway-namespace", "istio-system", "Namespace containing the Gateway API resources")
	flag.StringVar(&publicGatewayName, "public-gateway-name", "public-gateway", "Name of the platform public Gateway")
	flag.StringVar(&forgejoBaseURL, "forgejo-base-url", "https://forgejo-https.forgejo.svc.cluster.local", "Forgejo base URL (cluster-internal preferred)")
	flag.StringVar(&forgejoCASecretNamespace, "forgejo-ca-secret-namespace", "forgejo", "Namespace containing the Forgejo TLS certificate secret")
	flag.StringVar(&forgejoCASecretName, "forgejo-ca-secret-name", "forgejo-repo-tls", "Name of the Secret that stores Forgejo TLS cert data")
	flag.StringVar(&forgejoCASecretKey, "forgejo-ca-secret-key", "tls.crt", "Secret data key containing the Forgejo TLS certificate (PEM)")
	flag.StringVar(&controllerProfile, "controller-profile", "networking", "Controller profile to run: deployment-config|networking|forgejo|platform-apps|all")
	flag.BoolVar(&backupSystemWiringObserveOnly, "backup-system-wiring-observe-only", true, "Patch deployment-derived backup-system Cron schedules and static NFS PV mount fields, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&egressProxyObserveOnly, "egress-proxy-observe-only", true, "Compute/update TenantProject egress-proxy status, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&ingressCertsObserveOnly, "platform-ingress-certs-observe-only", true, "Compute deployment-derived platform ingress Certificates, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&ingressAdjacentObserveOnly, "ingress-adjacent-observe-only", true, "Patch deployment-derived ingress-adjacent hostnames (HTTPRoutes and related resources), but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&lokiLimitsObserveOnly, "loki-limits-observe-only", true, "Patch deployment-derived Loki limits in the rendered Loki config (ConfigMap/Secret), but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&dnsWiringObserveOnly, "dns-wiring-observe-only", true, "Create/update deployment-derived DNS wiring (PowerDNS/CoreDNS/external-sync), but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&cloudDNSObserveOnly, "cloud-dns-observe-only", true, "Create/update Cloud DNS zone and tenant credential wiring, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&keycloakUpstreamEgressObserveOnly, "keycloak-upstream-egress-observe-only", true, "Create/update deployment-derived Keycloak upstream egress NetworkPolicy allowlist, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&platformAppsObserveOnly, "platform-apps-observe-only", true, "Compute deployment PlatformApps-driven Argo Applications, but do not create/update/delete Kubernetes resources")
	flag.BoolVar(&postgresObserveOnly, "postgres-observe-only", true, "Create/update PostgresInstance backend resources, but do not create/update/delete Kubernetes resources")

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false, "Enable leader election for controller manager.")
	flag.StringVar(&leaderElectionID, "leader-election-id", "", "Leader election lease name override. Defaults to a profile-specific stable value.")

	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)

	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	scheme := runtime.NewScheme()
	utilruntime.Must(appsv1.AddToScheme(scheme))
	utilruntime.Must(batchv1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(networkingv1.AddToScheme(scheme))
	utilruntime.Must(policyv1.AddToScheme(scheme))
	utilruntime.Must(rbacv1.AddToScheme(scheme))
	utilruntime.Must(certmanagerv1.AddToScheme(scheme))
	utilruntime.Must(gatewayv1.AddToScheme(scheme))
	utilruntime.Must(tenancyv1alpha1.AddToScheme(scheme))
	utilruntime.Must(datav1alpha1.AddToScheme(scheme))

	cfg := controllers.Config{
		DeploymentConfig: controllers.DeploymentConfigSource{
			Namespace: deploymentConfigNamespace,
			Name:      deploymentConfigName,
			Key:       deploymentConfigKey,
		},
		DeploymentConfigSnapshot: controllers.DeploymentConfigSnapshotConfig{
			Name:       snapshotName,
			Key:        snapshotKey,
			Namespaces: splitCSV(snapshotNamespacesCSV),
		},
		Gateways: controllers.GatewayTargets{
			Namespace:         gatewayNamespace,
			PublicGatewayName: publicGatewayName,
		},
		Forgejo: controllers.ForgejoTargets{
			BaseURL:           forgejoBaseURL,
			CASecretNamespace: forgejoCASecretNamespace,
			CASecretName:      forgejoCASecretName,
			CASecretKey:       forgejoCASecretKey,
		},
		BackupSystemWiring: controllers.BackupSystemWiringConfig{
			ObserveOnly: backupSystemWiringObserveOnly,
		},
		EgressProxy: controllers.EgressProxyConfig{
			ObserveOnly: egressProxyObserveOnly,
		},
		IngressCerts: controllers.IngressCertsConfig{
			ObserveOnly: ingressCertsObserveOnly,
		},
		IngressAdjacent: controllers.IngressAdjacentConfig{
			ObserveOnly: ingressAdjacentObserveOnly,
		},
		LokiLimits: controllers.LokiLimitsConfig{
			ObserveOnly: lokiLimitsObserveOnly,
		},
		DNSWiring: controllers.DNSWiringConfig{
			ObserveOnly: dnsWiringObserveOnly,
		},
		CloudDNS: controllers.CloudDNSConfig{
			ObserveOnly: cloudDNSObserveOnly,
		},
		KeycloakUpstreamEgress: controllers.KeycloakUpstreamEgressConfig{
			ObserveOnly: keycloakUpstreamEgressObserveOnly,
		},
		PlatformApps: controllers.PlatformAppsConfig{
			ObserveOnly: platformAppsObserveOnly,
		},
		Postgres: controllers.PostgresConfig{
			ObserveOnly: postgresObserveOnly,
		},
	}

	switch controllerProfile {
	case "deployment-config", "networking", "forgejo", "platform-apps", "postgres", "all":
	default:
		ctrl.Log.Error(nil, "invalid controller profile", "controllerProfile", controllerProfile)
		os.Exit(2)
	}

	if leaderElectionID == "" {
		leaderElectionID = defaultLeaderElectionID(controllerProfile)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       leaderElectionID,
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if controllerProfile == "deployment-config" || controllerProfile == "all" {
		if err := (&controllers.DeploymentConfigSnapshotReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "DeploymentConfigSnapshot")
			os.Exit(1)
		}

		if err := (&controllers.BackupSystemWiringReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "BackupSystemWiring")
			os.Exit(1)
		}

		if err := (&controllers.KeycloakUpstreamEgressReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "KeycloakUpstreamEgress")
			os.Exit(1)
		}
	}

	if controllerProfile == "postgres" || controllerProfile == "all" {
		if err := (&controllers.PostgresReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "Postgres")
			os.Exit(1)
		}
	}

	if controllerProfile == "networking" || controllerProfile == "all" {
		if err := (&controllers.PublicGatewayReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "PublicGateway")
			os.Exit(1)
		}

		if err := (&controllers.TenantGatewayReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "TenantGateway")
			os.Exit(1)
		}

		if err := (&controllers.EgressProxyReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "EgressProxy")
			os.Exit(1)
		}

		if err := (&controllers.PlatformIngressCertificatesReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "PlatformIngressCertificates")
			os.Exit(1)
		}

		if err := (&controllers.IngressAdjacentReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "IngressAdjacent")
			os.Exit(1)
		}

		if err := (&controllers.LokiLimitsReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "LokiLimits")
			os.Exit(1)
		}

		if err := (&controllers.DNSWiringReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "DNSWiring")
			os.Exit(1)
		}

		if err := (&controllers.CloudDNSZoneReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "CloudDNSZone")
			os.Exit(1)
		}

		if err := (&controllers.TenantCloudDNSReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "TenantCloudDNS")
			os.Exit(1)
		}
	}

	if controllerProfile == "forgejo" || controllerProfile == "all" {
		if err := (&controllers.TenantForgejoReconciler{
			Client:    mgr.GetClient(),
			APIReader: mgr.GetAPIReader(),
			Scheme:    mgr.GetScheme(),
			Config:    cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "TenantForgejo")
			os.Exit(1)
		}
	}

	if controllerProfile == "platform-apps" || controllerProfile == "all" {
		if err := (&controllers.PlatformAppsReconciler{
			Client: mgr.GetClient(),
			Scheme: mgr.GetScheme(),
			Config: cfg,
		}).SetupWithManager(mgr); err != nil {
			ctrl.Log.Error(err, "unable to create controller", "controller", "PlatformApps")
			os.Exit(1)
		}
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	ctrl.Log.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "problem running manager")
		os.Exit(1)
	}
}

func splitCSV(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func defaultLeaderElectionID(controllerProfile string) string {
	switch controllerProfile {
	case "postgres":
		return "platform-postgres-controller.darksite.cloud"
	default:
		return "tenant-provisioner.darksite.cloud"
	}
}
