package controllers

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	ctrl "sigs.k8s.io/controller-runtime"

	tenancyv1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/tenancy/v1alpha1"
	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/forgejo"
	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/templates"
)

const (
	tenantProjectConditionForgejoReady = "ForgejoReady"
)

type TenantForgejoReconciler struct {
	client.Client
	APIReader client.Reader
	Scheme *runtime.Scheme
	Config Config
}

func (r *TenantForgejoReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	tp := &tenancyv1alpha1.TenantProject{}
	if err := r.Get(ctx, types.NamespacedName{Name: req.Name}, tp); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	fc, err := r.newForgejoClient(ctx)
	if err != nil {
		logger.Error(err, "missing forgejo controller config")
		r.setForgejoStatus(ctx, tp, metav1.ConditionFalse, "ConfigMissing", err.Error(), nil)
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	tenant := &tenancyv1alpha1.Tenant{}
	if err := r.Get(ctx, types.NamespacedName{Name: tp.Spec.TenantRef.Name}, tenant); err != nil {
		msg := fmt.Sprintf("referenced tenant missing: %s", tp.Spec.TenantRef.Name)
		r.setForgejoStatus(ctx, tp, metav1.ConditionFalse, "TenantMissing", msg, nil)
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	orgID := tenant.Spec.OrgID
	projectID := tp.Spec.ProjectID
	forgejoOrg := r.defaultForgejoOrg(tp, orgID)
	forgejoRepo := r.defaultForgejoRepo(tp, projectID)

	if err := ensureForgejoOrg(ctx, fc, forgejoOrg, tenant); err != nil {
		logger.Error(err, "failed to ensure forgejo org", "org", forgejoOrg)
		r.setForgejoStatus(ctx, tp, metav1.ConditionFalse, "OrgEnsureFailed", err.Error(), &tenancyv1alpha1.TenantProjectOutputs{
			Forgejo: &tenancyv1alpha1.TenantProjectForgejoOutputs{Org: forgejoOrg, Repo: forgejoRepo},
		})
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	repo, err := ensureForgejoRepo(ctx, fc, forgejoOrg, forgejoRepo, tp)
	if err != nil {
		logger.Error(err, "failed to ensure forgejo repo", "org", forgejoOrg, "repo", forgejoRepo)
		r.setForgejoStatus(ctx, tp, metav1.ConditionFalse, "RepoEnsureFailed", err.Error(), &tenancyv1alpha1.TenantProjectOutputs{
			Forgejo: &tenancyv1alpha1.TenantProjectForgejoOutputs{Org: forgejoOrg, Repo: forgejoRepo},
		})
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := ensureRepoSeeded(ctx, fc, forgejoOrg, forgejoRepo, orgID, projectID); err != nil {
		logger.Error(err, "failed to seed forgejo repo", "org", forgejoOrg, "repo", forgejoRepo)
		r.setForgejoStatus(ctx, tp, metav1.ConditionFalse, "RepoSeedFailed", err.Error(), &tenancyv1alpha1.TenantProjectOutputs{
			Forgejo: &tenancyv1alpha1.TenantProjectForgejoOutputs{Org: forgejoOrg, Repo: forgejoRepo, RepoURL: repo.CloneURL},
		})
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	r.setForgejoStatus(ctx, tp, metav1.ConditionTrue, "Provisioned", "forgejo org/repo provisioned", &tenancyv1alpha1.TenantProjectOutputs{
		Forgejo: &tenancyv1alpha1.TenantProjectForgejoOutputs{
			Org:     forgejoOrg,
			Repo:    forgejoRepo,
			RepoURL: repo.CloneURL,
		},
	})
	return ctrl.Result{}, nil
}

func (r *TenantForgejoReconciler) newForgejoClient(ctx context.Context) (*forgejo.Client, error) {
	baseURL := r.Config.Forgejo.BaseURL
	if baseURL == "" {
		baseURL = os.Getenv("FORGEJO_BASE_URL")
	}
	auth := forgejo.Auth{
		Token:    os.Getenv("FORGEJO_TOKEN"),
		Username: os.Getenv("FORGEJO_ADMIN_USERNAME"),
		Password: os.Getenv("FORGEJO_ADMIN_PASSWORD"),
	}

	httpClient := (*http.Client)(nil)
	if strings.HasPrefix(strings.ToLower(baseURL), "https://") {
		var err error
		httpClient, err = r.newForgejoHTTPClient(ctx)
		if err != nil {
			return nil, err
		}
	}

	return forgejo.NewWithHTTPClient(baseURL, auth, httpClient)
}

func (r *TenantForgejoReconciler) newForgejoHTTPClient(ctx context.Context) (*http.Client, error) {
	caNamespace := defaultString(
		r.Config.Forgejo.CASecretNamespace,
		os.Getenv("FORGEJO_CA_SECRET_NAMESPACE"),
		"forgejo",
	)
	caSecretName := defaultString(
		r.Config.Forgejo.CASecretName,
		os.Getenv("FORGEJO_CA_SECRET_NAME"),
		"forgejo-repo-tls",
	)
	caSecretKey := defaultString(
		r.Config.Forgejo.CASecretKey,
		os.Getenv("FORGEJO_CA_SECRET_KEY"),
		"tls.crt",
	)

	secret := &corev1.Secret{}
	reader := r.APIReader
	if reader == nil {
		reader = r.Client
	}
	if err := reader.Get(ctx, types.NamespacedName{Namespace: caNamespace, Name: caSecretName}, secret); err != nil {
		return nil, fmt.Errorf("read Forgejo TLS secret %s/%s: %w", caNamespace, caSecretName, err)
	}
	caPEM := secret.Data[caSecretKey]
	if len(caPEM) == 0 {
		return nil, fmt.Errorf("forgejo TLS secret %s/%s missing key %q", caNamespace, caSecretName, caSecretKey)
	}

	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	if ok := roots.AppendCertsFromPEM(caPEM); !ok {
		return nil, fmt.Errorf("forgejo TLS secret %s/%s key %q does not contain a valid PEM certificate", caNamespace, caSecretName, caSecretKey)
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
	}
	return &http.Client{
		Timeout:   20 * time.Second,
		Transport: transport,
	}, nil
}

func defaultString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func (r *TenantForgejoReconciler) defaultForgejoOrg(tp *tenancyv1alpha1.TenantProject, orgID string) string {
	if tp.Spec.Git != nil && tp.Spec.Git.ForgejoOrg != "" {
		return tp.Spec.Git.ForgejoOrg
	}
	return fmt.Sprintf("tenant-%s", orgID)
}

func (r *TenantForgejoReconciler) defaultForgejoRepo(tp *tenancyv1alpha1.TenantProject, projectID string) string {
	if tp.Spec.Git != nil && tp.Spec.Git.Repo != "" {
		return tp.Spec.Git.Repo
	}
	return fmt.Sprintf("apps-%s", projectID)
}

func (r *TenantForgejoReconciler) setForgejoStatus(ctx context.Context, tp *tenancyv1alpha1.TenantProject, status metav1.ConditionStatus, reason, message string, outputs *tenancyv1alpha1.TenantProjectOutputs) {
	tp.Status.ObservedGeneration = tp.Generation
	tp.Status.Outputs = outputs

	meta.SetStatusCondition(&tp.Status.Conditions, metav1.Condition{
		Type:               tenantProjectConditionForgejoReady,
		Status:             status,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: tp.Generation,
	})
	if err := r.Status().Update(ctx, tp); err != nil {
		log.FromContext(ctx).Error(err, "failed to update tenantproject status")
	}
}

func (r *TenantForgejoReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&tenancyv1alpha1.TenantProject{}).
		Complete(r)
}

func ensureForgejoOrg(ctx context.Context, fc *forgejo.Client, org string, tenant *tenancyv1alpha1.Tenant) error {
	if _, err := fc.GetOrg(ctx, org); err == nil {
		return nil
	} else if !forgejo.IsNotFound(err) {
		return err
	}

	desc := tenant.Spec.Description
	fullName := fmt.Sprintf("Tenant %s", tenant.Spec.OrgID)
	return fc.CreateOrg(ctx, forgejo.CreateOrgRequest{UserName: org, Description: desc, FullName: fullName})
}

func ensureForgejoRepo(ctx context.Context, fc *forgejo.Client, org, repo string, tp *tenancyv1alpha1.TenantProject) (*forgejo.Repo, error) {
	r, err := fc.GetRepo(ctx, org, repo)
	if err == nil {
		return r, nil
	}
	if !forgejo.IsNotFound(err) {
		return nil, err
	}

	desc := tp.Spec.Description
	if desc == "" {
		desc = fmt.Sprintf("Tenant project %s", tp.Spec.ProjectID)
	}

	if err := fc.CreateRepo(ctx, org, forgejo.CreateRepoRequest{
		Name:          repo,
		Description:   desc,
		Private:       true,
		DefaultBranch: "main",
	}); err != nil {
		return nil, err
	}
	return fc.GetRepo(ctx, org, repo)
}

func ensureRepoSeeded(ctx context.Context, fc *forgejo.Client, org, repo, orgID, projectID string) error {
	sentinel := ".deploykube/seed.yaml"
	if err := fc.GetFile(ctx, org, repo, sentinel); err == nil {
		return nil
	} else if !forgejo.IsNotFound(err) {
		return err
	}

	tenantNamespaceDev := fmt.Sprintf("t-%s-p-%s-dev-app", orgID, projectID)
	tenantNamespaceProd := fmt.Sprintf("t-%s-p-%s-prod-app", orgID, projectID)

	files := map[string][]byte{
		sentinel: []byte(fmt.Sprintf(
			"apiVersion: tenancy.darksite.cloud/v1alpha1\nkind: TenantRepoSeed\nmetadata:\n  template: default\n  createdAt: %s\n",
			time.Now().UTC().Format(time.RFC3339),
		)),
		"README.md": []byte(fmt.Sprintf(
			"# Tenant workload repo (%s/%s)\n\nThis repo was seeded by DeployKube.\n\n- Base manifests: `base/`\n- Deployment overlays: `overlays/<deploymentId>/`\n\nRequired PR checks:\n- `tenant-pr-gates`\n",
			orgID, projectID,
		)),
		"base/kustomization.yaml":                         []byte("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nresources: []\n"),
		"overlays/mac-orbstack/kustomization.yaml":        []byte(fmt.Sprintf("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nnamespace: %s\n\nresources:\n  - ../../base\n", tenantNamespaceDev)),
		"overlays/mac-orbstack-single/kustomization.yaml": []byte(fmt.Sprintf("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nnamespace: %s\n\nresources:\n  - ../../base\n", tenantNamespaceDev)),
		"overlays/proxmox-talos/kustomization.yaml":       []byte(fmt.Sprintf("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nnamespace: %s\n\nresources:\n  - ../../base\n", tenantNamespaceProd)),
	}

	staticFiles, err := readTemplateFiles("tenant-repo/default", templates.TenantRepoDefault)
	if err != nil {
		return err
	}
	for p, content := range staticFiles {
		files[p] = content
	}

	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	for _, p := range paths {
		content := base64.StdEncoding.EncodeToString(files[p])
		req := forgejo.CreateFileRequest{
			Content:   content,
			Message:   "Seed tenant repo (" + p + ")",
			Branch:    "main",
			NewBranch: "main",
		}
		if err := fc.CreateFile(ctx, org, repo, p, req); err != nil {
			if forgejo.IsAlreadyExists(err) {
				continue
			}
			// Forgejo may return 409/422 for the first commit race; keep retries simple.
			return fmt.Errorf("create file %s: %w", p, err)
		}
	}

	return nil
}

func readTemplateFiles(root string, fsys templates.FS) (map[string][]byte, error) {
	out := make(map[string][]byte)

	paths, err := fsys.ListFiles(root)
	if err != nil {
		return nil, err
	}
	for _, p := range paths {
		rel := strings.TrimPrefix(p, root+"/")
		b, err := fsys.ReadFile(p)
		if err != nil {
			return nil, err
		}
		out[rel] = b
	}
	return out, nil
}
