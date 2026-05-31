podman run --rm -i quay.io/coreos/butane:release \
  --pretty --strict < config/butane/local.bu \
  > config/ignition/local.ign