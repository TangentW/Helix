#!/bin/sh
set -eu

workflow="${1:?usage: DemoBootstrap.sh hot|live}"
script_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
demo_root="$(dirname "$script_directory")"
repository_root="$(dirname "$demo_root")"
helix_executable="$repository_root/.build/debug/helix"

if [ ! -x "$helix_executable" ]; then
    echo "Helix Demo: building the local helix executable once."
    env -u SDKROOT -u PLATFORM_NAME -u CURRENT_ARCH -u ARCHS \
        /usr/bin/swift build \
        --package-path "$repository_root" \
        --product helix
fi

case "$workflow" in
    live)
        ;;
    hot)
        identity_root="$demo_root/.helix/private"
        mkdir -p "$demo_root/.helix"
        complete_identity=true
        for name in TrustedRoot.json SigningCertificate.json PatchSigningKey.json; do
            if [ ! -f "$identity_root/$name" ]; then
                complete_identity=false
            fi
        done
        if [ "$complete_identity" != true ]; then
            echo "Helix Demo: creating an isolated local signing identity."
            "$helix_executable" patch create-development-identity \
                --bundle-id dev.helix.hot-patch-demo \
                --output "$identity_root" \
                --validity-days 1825 \
                --force
        fi
        ;;
    *)
        echo "error: unknown Helix Demo workflow: $workflow" >&2
        exit 2
        ;;
esac
