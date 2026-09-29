# ---------------------------------------------------------------- shared check
# Ollama reachable FROM A CONTAINER, which is not the same question as reachable
# from the host. Ollama listens on 127.0.0.1 and Docker Desktop forwards
# host.docker.internal to it. That forward drops when the host changes network --
# joining conference Wi-Fi, unplugging Ethernet, toggling Wi-Fi for an offline
# test -- and it comes back on its own, which is why it reads as flaky.
#
# When it is down, the agent does not say so. It reports:
#   FailoverError: LLM request failed: the provider endpoint is unreachable
#   ... connect ENETUNREACH 192.168.65.254:11434
# which sends you hunting for a model or policy bug. Checking it up front turns
# a confusing ten-minute detour into one line with the fix in it.
ollama_reachable_from_container() {
  docker run --rm --add-host host.docker.internal:host-gateway \
    --entrypoint curl harness-openclaw:2026.7.1 \
    -fsS -m 6 http://host.docker.internal:11434/api/version >/dev/null 2>&1
}

ollama_container_hint() {
  cat <<'HINT'
  The host can reach Ollama but a container cannot. Docker Desktop's route to
  the host has dropped, which usually happens right after the machine changed
  network. Fix it with one of these, cheapest first:

    1. docker compose down && docker compose up -d --wait openclaw-gateway
    2. Restart Docker Desktop (Settings menu > Restart), then retry
    3. Confirm Ollama is up on the host: curl http://127.0.0.1:11434/api/version

  On Linux this is usually a different problem with the same symptom. Ollama
  binds 127.0.0.1 by default, and Docker on Linux resolves host.docker.internal
  to a bridge address rather than to loopback, so the container cannot reach it
  however healthy the host looks. Restart Ollama bound to the bridge:

    OLLAMA_HOST=0.0.0.0:11434 ollama serve

  Bind it no wider than your machine needs; 0.0.0.0 exposes the model API to
  your local network.

  This is not a model, policy, or lab problem, and it clears on its own once the
  network settles.
HINT
}
