# apps/

Workload manifests live here — one directory per application.

This directory is the **GitOps source of truth** for applications. Once ArgoCD is
installed (Phase 7), an ArgoCD `Application` (app-of-apps) watches this path and
reconciles whatever is committed here into the cluster. Nothing is applied by hand;
`git push` is the deploy.

Layout convention:

```
apps/
  <app-name>/
    deployment.yaml
    service.yaml
    ingress.yaml
    kustomization.yaml
```

CI (`.github/workflows/validate.yml`) runs `kubeconform` against every manifest here.
