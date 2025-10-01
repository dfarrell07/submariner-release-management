# Submariner Release Management

Release YAML files for Submariner releases via Konflux.

## Usage

Login: `oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/`

Apply: `oc apply -n submariner-tenant -f releases/0.20/stage/submariner-0-20-2-stage-20250930-01.yaml`
