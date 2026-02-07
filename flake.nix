{
  description = "RS-SDK local development flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        startScript = pkgs.writeShellApplication {
          name = "start";
          runtimeInputs = with pkgs; [ bun coreutils jre_headless lsof curl gnugrep firefox ];
          text = ''
            set -euo pipefail

            export PUPPETEER_EXECUTABLE_PATH="${pkgs.firefox}/bin/firefox"
            export SDK_PUPPETEER_BROWSER=firefox

            if [ ! -d engine ] || [ ! -d webclient ] || [ ! -d gateway ] || [ ! -d mcp ]; then
              echo "Run this command from the repository root (missing engine/webclient/gateway/mcp)." >&2
              exit 1
            fi

            install_if_needed() {
              local dir="$1"
              if [ ! -d "$dir/node_modules" ]; then
                echo "[start] Installing dependencies in $dir..."
                (
                  cd "$dir"
                  if ! bun install --frozen-lockfile; then
                    bun install
                  fi
                )
              fi
            }

            prepare_engine_content_if_needed() {
              if [ ! -f engine/data/pack/server/script.dat ]; then
                echo "[start] Packed server scripts missing; running engine build..."
                (cd engine && bun run build)
              fi
            }

            sync_webclient_artifacts() {
              mkdir -p engine/public/client engine/public/bot

              [ -f webclient/out/standard/client.js ] && cp webclient/out/standard/client.js engine/public/client/client.js
              [ -f webclient/out/standard/deps.js ] && cp webclient/out/standard/deps.js engine/public/client/deps.js
              [ -f webclient/out/standard/bzip2.wasm ] && cp webclient/out/standard/bzip2.wasm engine/public/client/bzip2.wasm
              [ -f webclient/out/standard/tinymidipcm.wasm ] && cp webclient/out/standard/tinymidipcm.wasm engine/public/client/tinymidipcm.wasm
              [ -f webclient/out/bot/client.js ] && cp webclient/out/bot/client.js engine/public/bot/client.js
              [ -f webclient/out/bot/deps.js ] && cp webclient/out/bot/deps.js engine/public/bot/deps.js
              [ -f webclient/out/bot/bzip2.wasm ] && cp webclient/out/bot/bzip2.wasm engine/public/bot/bzip2.wasm
              [ -f webclient/out/bot/tinymidipcm.wasm ] && cp webclient/out/bot/tinymidipcm.wasm engine/public/bot/tinymidipcm.wasm
            }

            cleanup() {
              trap - INT TERM EXIT
              kill 0 || true
            }
            trap cleanup INT TERM EXIT

            install_if_needed engine
            install_if_needed webclient
            install_if_needed gateway
            prepare_engine_content_if_needed

            gateway_port="7780"

            # Reuse existing gateway only if it looks like the RS-SDK gateway service.
            if lsof -tiTCP:"$gateway_port" -sTCP:LISTEN >/dev/null 2>&1; then
              if curl -fsS "http://127.0.0.1:$gateway_port/" 2>/dev/null | grep -q "Gateway Service"; then
                echo "[start] Reusing existing gateway on port $gateway_port."
              else
                echo "[start] Port $gateway_port is busy with a non-gateway process; selecting a new gateway port..."
                gateway_port="7781"
                while lsof -tiTCP:"$gateway_port" -sTCP:LISTEN >/dev/null 2>&1; do
                  gateway_port="$((gateway_port + 1))"
                done
              fi
            fi

            echo "[start] Starting webclient watcher..."
            (cd webclient && bun run watch) &

            echo "[start] Starting webclient -> engine sync..."
            (
              while true; do
                sync_webclient_artifacts || true
                sleep 1
              done
            ) &

            if curl -fsS "http://127.0.0.1:$gateway_port/" 2>/dev/null | grep -q "Gateway Service"; then
              echo "[start] Gateway already available on port $gateway_port."
            else
              echo "[start] Starting gateway on port $gateway_port..."
              (cd gateway && AGENT_PORT="$gateway_port" bun run gateway) &
            fi

            echo "[start] Starting engine..."
            (cd engine && NODE_XPRATE=32 GATEWAY_URL="http://localhost:$gateway_port" bun run quickstart) &

            wait_for_http() {
              local url="$1"
              local name="$2"
              local attempts=60
              local i=0
              until curl -fsS "$url" >/dev/null 2>&1; do
                i="$((i + 1))"
                if [ "$i" -ge "$attempts" ]; then
                  echo "[start] ERROR: $name did not become ready at $url" >&2
                  exit 1
                fi
                sleep 1
              done
              echo "[start] Ready: $name ($url)"
            }

            wait_for_http "http://localhost:$gateway_port/" "gateway"
            wait_for_http "http://localhost:8888/rs2.cgi" "engine web endpoint"

            echo "[start] Local stack is running (engine + webclient watch + gateway on $gateway_port)."
            wait
          '';
        };
      in
      {
        packages = {
          start = startScript;
          default = startScript;
        };

        apps = {
          start = {
            type = "app";
            program = "${startScript}/bin/start";
          };
          default = self.apps.${system}.start;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ bun startScript firefox ];
          shellHook = ''
            export PUPPETEER_EXECUTABLE_PATH="${pkgs.firefox}/bin/firefox"
            export SDK_PUPPETEER_BROWSER=firefox
          '';
        };
      });
}
