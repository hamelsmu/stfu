set dotenv-load := true

version := env_var_or_default("VERSION", "0.1.0")

default:
    just --list

build:
    swift build -c release

package:
    VERSION={{version}} scripts/package.sh

# Build package artifacts, then verify the generated DMG/pkg.
verify: package
    VERIFY_EXISTING=1 VERSION={{version}} scripts/verify.sh

# Verify existing artifacts after a fresh package step without rerunning scripts/package.sh.
verify-existing:
    VERIFY_EXISTING=1 VERSION={{version}} scripts/verify.sh

install-local: package
    ditto .build/installer/payload/Applications/STFU.app /Applications/STFU.app
    install -m 755 .build/installer/payload/usr/local/bin/stfu /usr/local/bin/stfu

open:
    open -a /Applications/STFU.app

doctor:
    /usr/local/bin/stfu --doctor

release:
    VERSION={{version}} scripts/release.sh {{version}}

release-version version:
    VERSION={{version}} scripts/release.sh {{version}}
