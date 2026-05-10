set dotenv-load := true

version := env_var_or_default("VERSION", "0.1.1")

default:
    just --list

build:
    swift build -c release

package:
    VERSION={{version}} scripts/package.sh

verify:
    VERSION={{version}} scripts/verify.sh

verify-existing:
    VERIFY_EXISTING=1 VERSION={{version}} scripts/verify.sh

install-local: package
    ditto .build/installer/payload/Applications/STFU.app /Applications/STFU.app
    rm -rf "/Applications/STFU Menu.app"
    install -m 755 .build/installer/payload/usr/local/bin/stfu /usr/local/bin/stfu

open:
    open -a /Applications/STFU.app

open-menu:
    open -a /Applications/STFU.app

doctor:
    /usr/local/bin/stfu --doctor

release:
    VERSION={{version}} scripts/release.sh {{version}}

release-version version:
    VERSION={{version}} scripts/release.sh {{version}}
