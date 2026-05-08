# Reference: Active Verification Patterns

Reusable patterns for exercising operator PR changes on a live cluster. The workflow (`../workflows/review-operator-pr.md`) selects which patterns to run based on the diff categories from Phase 5.

Cross-reference: `../../rhdh/references/rhdh-repos.md` for operator architecture — CRD spec structure, reconciliation flow (phases, preprocessing, status updates), auto-refresh labels (`rhdh.redhat.com/ext-config-sync`), and key file paths.

<baseline_capture>

## Capturing Pre-Verification State

Snapshot the cluster state before any verification actions. Used for before/after comparison and rollback.

```bash
RHDH_NS=$(oc get backstage -A --no-headers | head -1 | awk '{print $1}')
BACKSTAGE_NAME=$(oc get backstage -n $RHDH_NS --no-headers | head -1 | awk '{print $1}')
BACKSTAGE_DEPLOY=$(oc get deployment -n $RHDH_NS --no-headers \
  -o custom-columns=NAME:.metadata.name | grep backstage | grep -v psql | head -1)

# Pod spec snapshot
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS -o yaml > /tmp/pre-verify-deploy.yaml

# CR snapshot
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS -o yaml > /tmp/pre-verify-cr.yaml

# ConfigMap list
oc get configmap -n $RHDH_NS -o name > /tmp/pre-verify-configmaps.txt

# Events bookmark
oc get events -n $RHDH_NS --sort-by=.lastTimestamp --no-headers | tail -1

# Operator log timestamp (for filtering logs to only post-verification entries)
BASELINE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

</baseline_capture>

<configmap_verification>

## ConfigMap / Volume Mount Changes

For PRs that change how ConfigMap keys are iterated, mounted, or ordered (e.g., `pkg/model/appconfig.go`, `pkg/model/configmapfiles.go`, volume mount logic).

### Create a multi-key test ConfigMap

```bash
cat <<'EOF' | oc apply -n $RHDH_NS -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-multikey-appconfig
  labels:
    rhdh.redhat.com/ext-config-sync: "true"
data:
  app-config-z.yaml: |
    app:
      title: "Z-Config"
  app-config-a.yaml: |
    app:
      baseUrl: "https://test-a.example.com"
  app-config-m.yaml: |
    backend:
      reading:
        allow:
          - host: "test-m.example.com"
EOF
```

### Attach to Backstage CR

```bash
oc patch backstage $BACKSTAGE_NAME -n $RHDH_NS --type='merge' \
  -p='{"spec":{"application":{"appConfig":{"configMaps":[{"name":"test-multikey-appconfig"}]}}}}'
```

### Verify deterministic mount ordering

Wait for reconciliation, then check volume mounts appear in a stable (sorted) order:

```bash
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s

# Capture volume mounts — should show keys in alphabetical order (a, m, z)
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}: {.mountPath}{"\n"}{end}'

# Capture --config args — should also be in alphabetical order
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```

### Verify stability across reconciliations

Trigger multiple reconciliations and confirm the pod spec does not change:

```bash
# Capture pod spec hash after first reconciliation
SPEC_HASH_1=$(oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{.spec.template}' | sha256sum | awk '{print $1}')

# Trigger reconciliation via annotation
oc annotate backstage $BACKSTAGE_NAME -n $RHDH_NS \
  test-reconcile-1=$(date +%s) --overwrite
sleep 10

SPEC_HASH_2=$(oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{.spec.template}' | sha256sum | awk '{print $1}')

# Trigger again
oc annotate backstage $BACKSTAGE_NAME -n $RHDH_NS \
  test-reconcile-2=$(date +%s) --overwrite
sleep 10

SPEC_HASH_3=$(oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{.spec.template}' | sha256sum | awk '{print $1}')

echo "Hash 1: $SPEC_HASH_1"
echo "Hash 2: $SPEC_HASH_2"
echo "Hash 3: $SPEC_HASH_3"

if [ "$SPEC_HASH_1" = "$SPEC_HASH_2" ] && [ "$SPEC_HASH_2" = "$SPEC_HASH_3" ]; then
  echo "PASS: Pod spec is deterministic across reconciliations"
else
  echo "FAIL: Pod spec changed between reconciliations"
fi
```

### Check config hash annotation

```bash
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS \
  -o jsonpath='{.spec.template.metadata.annotations.rhdh\.redhat\.com/ext-config-hash}'
```

### Cleanup

```bash
oc patch backstage $BACKSTAGE_NAME -n $RHDH_NS --type='merge' \
  -p='{"spec":{"application":{"appConfig":{"configMaps":null}}}}'
oc delete configmap test-multikey-appconfig -n $RHDH_NS
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s
```

</configmap_verification>

<crd_api_verification>

## CRD / API Field Changes

For PRs that modify `api/v1alpha5/backstage_types.go` or related CRD definitions.

### Verify new field schema

```bash
# Replace <field> with the actual field path from the diff
oc explain backstage.spec.<field>
```

### Apply CR with new field

Derive the field name and expected type from the diff. Create a test CR or patch the existing one:

```bash
oc patch backstage $BACKSTAGE_NAME -n $RHDH_NS --type='merge' \
  -p='{"spec":{"<field>":"<value>"}}'
```

### Backward compatibility — apply CR without new field

```bash
# Restore original CR spec
oc apply -n $RHDH_NS -f /tmp/pre-verify-cr.yaml
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s

# Verify reconciliation succeeds
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS -o jsonpath='{.status.conditions}'
```

### Cleanup

Restore original CR from baseline snapshot if modified.

</crd_api_verification>

<controller_verification>

## Controller / Reconciler Changes

For PRs that modify `internal/controller/` or `pkg/model/`. See `rhdh-repos.md` for the reconciliation flow: preprocess spec → init object model (Phase 1-3) → apply → clean up → update status.

### Trigger reconciliation

```bash
oc annotate backstage $BACKSTAGE_NAME -n $RHDH_NS \
  test-reconcile=$(date +%s) --overwrite
```

### Watch operator logs for reconciliation

```bash
oc logs deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS \
  --since-time=$BASELINE_TS --follow &
LOG_PID=$!
sleep 15
kill $LOG_PID 2>/dev/null
```

### Verify status conditions

```bash
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}){"\n"}{end}'
```

### Delete and recreate CR — clean reconciliation

```bash
# Save current CR
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS -o yaml > /tmp/test-cr-backup.yaml

# Delete
oc delete backstage $BACKSTAGE_NAME -n $RHDH_NS --wait=true

# Wait for resources to clean up
sleep 10

# Recreate
oc apply -n $RHDH_NS -f /tmp/test-cr-backup.yaml

# Wait for full reconciliation
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=180s

# Verify health
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS
oc get pods -n $RHDH_NS
```

### Cleanup

No cleanup needed — CR is restored to its pre-test state by the recreate step.

</controller_verification>

<default_config_verification>

## Default Config Changes

For PRs that modify `config/profile/rhdh/default-config/` or similar default manifests.

### Deploy minimal CR and verify defaults

```bash
# Save existing CR
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS -o yaml > /tmp/test-cr-backup.yaml

# Apply minimal CR (defaults only)
cat <<EOF | oc apply -n $RHDH_NS -f -
apiVersion: rhdh.redhat.com/v1alpha5
kind: Backstage
metadata:
  name: $BACKSTAGE_NAME
spec: {}
EOF

oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s
```

### Compare against expected defaults

```bash
# Capture resulting pod spec
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS -o yaml > /tmp/post-defaults-deploy.yaml

# Diff against pre-verification baseline
diff /tmp/pre-verify-deploy.yaml /tmp/post-defaults-deploy.yaml
```

### Cleanup

```bash
oc apply -n $RHDH_NS -f /tmp/test-cr-backup.yaml
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s
```

</default_config_verification>

<dependency_verification>

## Dependency Changes

For PRs that modify `go.mod` or `go.sum`.

### Check runtime impact

```bash
# Pod startup time
oc get pods -n $OPERATOR_NS -l control-plane=controller-manager \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}'

# Memory usage
oc top pod -n $OPERATOR_NS -l control-plane=controller-manager

# Log warnings about deprecated APIs
oc logs deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS --since-time=$BASELINE_TS \
  | grep -iE "deprecated|warning|obsolete" || echo "No deprecation warnings found"
```

</dependency_verification>

<evidence_capture>

## Evidence Collection

Run after each verification action to capture results for the findings report.

```bash
# Operator logs since baseline
oc logs deployment/$OPERATOR_DEPLOY -n $OPERATOR_NS --since-time=$BASELINE_TS

# Pod spec diff against baseline
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS -o yaml > /tmp/post-verify-deploy.yaml
diff /tmp/pre-verify-deploy.yaml /tmp/post-verify-deploy.yaml || true

# Events since baseline
oc get events -n $RHDH_NS --sort-by=.lastTimestamp

# CR status conditions
oc get backstage $BACKSTAGE_NAME -n $RHDH_NS \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) - {.message}{"\n"}{end}'

# Pod health
oc get pods -n $RHDH_NS -o wide
oc get pods -n $OPERATOR_NS -l control-plane=controller-manager -o wide
```

</evidence_capture>

<cleanup_patterns>

## Cleanup After Verification

Final restoration after all verification steps. Ensures the cluster returns to pre-verification state.

```bash
# Remove any test ConfigMaps
oc delete configmap -n $RHDH_NS -l test-verification=true 2>/dev/null || true
oc delete configmap test-multikey-appconfig -n $RHDH_NS 2>/dev/null || true

# Restore original CR spec
oc apply -n $RHDH_NS -f /tmp/pre-verify-cr.yaml

# Wait for reconciliation
oc rollout status deployment/$BACKSTAGE_DEPLOY -n $RHDH_NS --timeout=120s

# Verify restoration
oc get deployment $BACKSTAGE_DEPLOY -n $RHDH_NS -o yaml > /tmp/post-cleanup-deploy.yaml
diff /tmp/pre-verify-deploy.yaml /tmp/post-cleanup-deploy.yaml && \
  echo "PASS: Cluster restored to pre-verification state" || \
  echo "WARN: Cluster state differs from pre-verification baseline"

# Remove test annotations from CR
oc annotate backstage $BACKSTAGE_NAME -n $RHDH_NS \
  test-reconcile- test-reconcile-1- test-reconcile-2- 2>/dev/null || true

# Clean up temp files
rm -f /tmp/pre-verify-*.yaml /tmp/post-verify-*.yaml /tmp/post-defaults-deploy.yaml \
  /tmp/post-cleanup-deploy.yaml /tmp/test-cr-backup.yaml
```

</cleanup_patterns>
