#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
cd "$ROOT_DIR"

GCANNON="${GCANNON:-/home/diogo/Desktop/Socket/gcannon/gcannon}"
HARD_NOFILE=$(ulimit -Hn)
ulimit -n "$HARD_NOFILE"
THREADS=12
DURATION=5s
RUNS=3
PORT=8080
REQUESTS_DIR="$ROOT_DIR/requests"
RESULTS_DIR="$ROOT_DIR/results"

# Profile definitions: pipeline|req_per_conn|cpu_limit|connections
# connections is a comma-separated list
declare -A PROFILES=(
    [baseline]="1|0||512,4096,16384"
    [pipelined]="16|0||512,4096,16384"
    [limited-conn]="1|10||512,4096"
    [cpu-limited]="1|0|12|512,4096"
)
PROFILE_ORDER=(baseline pipelined limited-conn cpu-limited)

# Usage: benchmark.sh [framework] [profile]
FRAMEWORK="${1:-}"
PROFILE_FILTER="${2:-}"

# If no framework, run all
if [ -z "$FRAMEWORK" ]; then
    for fw in $(ls -d "$ROOT_DIR"/frameworks/*/ | xargs -n1 basename); do
        "$SCRIPT_DIR/benchmark.sh" "$fw" "$PROFILE_FILTER"
    done
    rebuild_site_data() {
        local site_data="$ROOT_DIR/site/data"
        mkdir -p "$site_data"
        for profile_dir in "$RESULTS_DIR"/*/; do
            [ -d "$profile_dir" ] || continue
            local profile=$(basename "$profile_dir")
            for conn_dir in "$profile_dir"/*/; do
                [ -d "$conn_dir" ] || continue
                local conns=$(basename "$conn_dir")
                local data_file="$site_data/${profile}-${conns}.json"
                echo '[' > "$data_file"
                local first=true
                for f in "$conn_dir"/*.json; do
                    [ -f "$f" ] || continue
                    $first || echo ',' >> "$data_file"
                    cat "$f" >> "$data_file"
                    first=false
                done
                echo ']' >> "$data_file"
                echo "[updated] site/data/${profile}-${conns}.json"
            done
        done
    }
    rebuild_site_data
    exit 0
fi

IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-bench-${FRAMEWORK}"

# Read metadata from framework meta.json
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
LANGUAGE=""
DISPLAY_NAME="$FRAMEWORK"
if [ -f "$META_FILE" ]; then
    LANGUAGE=$(grep -oP '"language"\s*:\s*"\K[^"]+' "$META_FILE")
    dn=$(grep -oP '"display_name"\s*:\s*"\K[^"]+' "$META_FILE")
    [ -n "$dn" ] && DISPLAY_NAME="$dn"
fi

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Stop any httparena containers
docker ps -aq --filter "name=httparena-" | xargs -r docker rm -f 2>/dev/null || true

# Build once
echo "=== Building: $FRAMEWORK ==="
if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
    "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: build"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: build"; exit 1; }
fi

# Determine which profiles to run
if [ -n "$PROFILE_FILTER" ]; then
    profiles_to_run=("$PROFILE_FILTER")
else
    profiles_to_run=("${PROFILE_ORDER[@]}")
fi

for profile in "${profiles_to_run[@]}"; do
    IFS='|' read -r pipeline req_per_conn cpu_limit conn_list <<< "${PROFILES[$profile]}"

    # Parse connection counts
    IFS=',' read -ra CONN_COUNTS <<< "$conn_list"

    for CONNS in "${CONN_COUNTS[@]}"; do

    echo ""
    echo "=============================================="
    echo "=== $FRAMEWORK / $profile / ${CONNS}c (p=$pipeline, r=${req_per_conn:-unlimited}, cpu=${cpu_limit:-unlimited}) ==="
    echo "=============================================="

    # (Re)start container with profile-specific flags
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker_args=(-d --name "$CONTAINER_NAME" --network host
        --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1
        --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
    if [ -n "$cpu_limit" ]; then
        docker_args+=(--cpus="$cpu_limit")
    fi
    docker run "${docker_args[@]}" "$IMAGE_NAME"

    # Wait for server
    echo "[wait] Waiting for server..."
    for i in $(seq 1 30); do
        if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/bench?a=1&b=1" 2>/dev/null; then
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "FAIL: Server did not start within 30s"
            exit 1
        fi
        sleep 1
    done
    echo "[ready] Server is up"

    # Build gcannon args — pipelined profile uses lightweight /pipeline endpoint
    if [ "$profile" = "pipelined" ]; then
        gc_args=("http://localhost:$PORT/pipeline"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    else
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/post_cl.raw,$REQUESTS_DIR/post_chunked.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    fi
    if [ "$req_per_conn" -gt 0 ] 2>/dev/null; then
        gc_args+=(-r "$req_per_conn")
    fi

    # Best-of-N runs
    best_rps=0
    best_output=""
    best_cpu="0%"
    best_mem="0MiB"

    for run in $(seq 1 $RUNS); do
        echo ""
        echo "[run $run/$RUNS]"

        stats_log=$(mktemp)
        while true; do
            docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$CONTAINER_NAME" >> "$stats_log" 2>/dev/null
        done &
        stats_pid=$!

        output=$("$GCANNON" "${gc_args[@]}" 2>&1) || true

        kill "$stats_pid" 2>/dev/null; wait "$stats_pid" 2>/dev/null || true

        avg_cpu=$(awk '{gsub(/%/,"",$1); if($1+0>0){sum+=$1; n++}} END{if(n>0) printf "%.1f%%", sum/n; else print "0%"}' "$stats_log")
        peak_mem=$(awk '{split($2,a,"/"); gsub(/[^0-9.]/,"",a[1]); unit=$2; gsub(/[0-9.]/,"",unit); if(a[1]+0>max){max=a[1]+0; u=unit}} END{if(max>0) printf "%.1f%s", max, u; else print "0MiB"}' "$stats_log")
        rm -f "$stats_log"

        echo "$output"
        echo "  CPU: $avg_cpu | Mem: $peak_mem"

        req_count=$(echo "$output" | grep -oP '(\d+) requests in' | grep -oP '\d+' || echo "0")
        duration_secs=$(echo "$output" | grep -oP 'requests in ([\d.]+)s' | grep -oP '[\d.]+' || echo "1")
        rps_int=$(echo "$req_count / $duration_secs" | bc | cut -d. -f1)
        rps_int=${rps_int:-0}

        if [ "$rps_int" -gt "$best_rps" ]; then
            best_rps=$rps_int
            best_output="$output"
            best_cpu="$avg_cpu"
            best_mem="$peak_mem"
        fi

        sleep 2
    done

    echo ""
    echo "=== Best: ${best_rps} req/s (CPU: $best_cpu, Mem: $best_mem) ==="

    # Extract metrics
    avg_lat=$(echo "$best_output" | grep "Latency" | head -1 | awk '{print $2}')
    p99_lat=$(echo "$best_output" | grep "Latency" | head -1 | awk '{print $5}')
    reconnects=$(echo "$best_output" | grep -oP 'Reconnects: \K\d+' || echo "0")

    # Save results — subdirectory per connection count
    mkdir -p "$RESULTS_DIR/$profile/$CONNS"
    cat > "$RESULTS_DIR/$profile/${CONNS}/${FRAMEWORK}.json" <<EOF
{
  "framework": "$DISPLAY_NAME",
  "language": "$LANGUAGE",
  "rps": $best_rps,
  "avg_latency": "$avg_lat",
  "p99_latency": "$p99_lat",
  "cpu": "$best_cpu",
  "memory": "$best_mem",
  "connections": $CONNS,
  "threads": $THREADS,
  "duration": "$DURATION",
  "pipeline": $pipeline,
  "reconnects": $reconnects
}
EOF
    echo "[saved] results/$profile/${CONNS}/${FRAMEWORK}.json"

    # Save docker logs
    LOGS_DIR="$ROOT_DIR/site/static/logs/$profile/$CONNS"
    mkdir -p "$LOGS_DIR"
    docker logs "$CONTAINER_NAME" > "$LOGS_DIR/${FRAMEWORK}.log" 2>&1 || true
    echo "[saved] site/static/logs/$profile/${CONNS}/${FRAMEWORK}.log"

    # Stop container before next connection count
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    done # CONNS loop
done

# Rebuild site data
SITE_DATA="$ROOT_DIR/site/data"
mkdir -p "$SITE_DATA"
for profile_dir in "$RESULTS_DIR"/*/; do
    [ -d "$profile_dir" ] || continue
    profile=$(basename "$profile_dir")
    for conn_dir in "$profile_dir"/*/; do
        [ -d "$conn_dir" ] || continue
        conns=$(basename "$conn_dir")
        data_file="$SITE_DATA/${profile}-${conns}.json"
        echo '[' > "$data_file"
        first=true
        for f in "$conn_dir"/*.json; do
            [ -f "$f" ] || continue
            $first || echo ',' >> "$data_file"
            cat "$f" >> "$data_file"
            first=false
        done
        echo ']' >> "$data_file"
        echo "[updated] site/data/${profile}-${conns}.json"
    done
done
