#!/bin/sh

# Sends the quit signal to the Istio sidecar (if present) so native-sidecar Jobs
# can terminate immediately instead of waiting for envoy's drain timeout.
deploykube_istio_quit_sidecar() {
  max_attempts="${DEPLOYKUBE_ISTIO_QUIT_ATTEMPTS:-30}"
  strict="${DEPLOYKUBE_ISTIO_QUIT_STRICT:-false}"

  quit_with_curl() {
    i=0
    while [ "$i" -lt "$max_attempts" ]; do
      curl -fsS -XPOST --max-time 1 \
        http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 && return 0
      i=$((i + 1))
      sleep 1
    done
    return 1
  }

  quit_with_wget() {
    i=0
    while [ "$i" -lt "$max_attempts" ]; do
      wget -qO- --timeout=1 --post-data='' \
        http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 && return 0
      i=$((i + 1))
      sleep 1
    done
    return 1
  }

  quit_with_busybox_wget() {
    i=0
    while [ "$i" -lt "$max_attempts" ]; do
      busybox wget -qO- --timeout=1 --post-data='' \
        http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 && return 0
      i=$((i + 1))
      sleep 1
    done
    return 1
  }

  if command -v curl >/dev/null 2>&1; then
    # Some fast-exiting Jobs may run their EXIT trap before the pilot-agent status
    # server is ready. Retry briefly to avoid leaving istio-proxy running and
    # wedging the Job in "Running".
    if quit_with_curl; then
      return 0
    fi
    if [ "$strict" = "true" ]; then
      return 1
    fi
    # If the quit endpoint never becomes reachable, assume no sidecar was injected
    # (or the namespace isn't mesh-managed) and avoid failing the workload.
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    if quit_with_wget; then
      return 0
    fi
    if [ "$strict" = "true" ]; then
      return 1
    fi
    return 0
  fi

  if command -v busybox >/dev/null 2>&1; then
    if quit_with_busybox_wget; then
      return 0
    fi
    if [ "$strict" = "true" ]; then
      return 1
    fi
    return 0
  fi

  # No HTTP client available; treat as no-op by default.
  if [ "$strict" = "true" ]; then
    return 1
  fi
  return 0
}
