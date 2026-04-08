package templates

import "embed"

//go:embed tenant-repo/default/**
var tenantRepoDefault embed.FS

var TenantRepoDefault FS = EmbedFS{fs: tenantRepoDefault}
