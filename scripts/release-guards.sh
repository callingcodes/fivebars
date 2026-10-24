# Guard functions for scripts/release.sh, sourced by it (and by tests). Each prints an
# "error: ..." line and returns non-zero on failure; the caller decides to exit.
# Nothing here uploads anything.

guard_error() { echo "error: $*" >&2; return 1; }

# Fetch the live appcast to $2. Only a 404 means "first release" (empty file); any other
# failure aborts, so a transient error can't drop the feed's history. A 200 must be a feed.
fetch_appcast() {
    local url="$1" out="$2" code
    code="$(curl -sS -o "$out" -w '%{http_code}' -H 'Cache-Control: no-cache' "$url?fresh=$(date +%s)")" \
        || guard_error "could not fetch the live appcast $url (network); refusing to drop its history" || return 1
    case "$code" in
        200) grep -q "<channel>" "$out" || guard_error "the live appcast $url has no <channel>; refusing to replace it" || return 1 ;;
        404) : > "$out"; echo "No live appcast yet (404): this is the first release." ;;
        *) guard_error "the live appcast $url answered HTTP $code; refusing to drop its history" || return 1 ;;
    esac
}

# Highest <sparkle:version> in an appcast file (0 when it has none).
max_sparkle_version() {
    { grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$1" | grep -o '[0-9][0-9]*'; echo 0; } | sort -n | tail -1
}

# A new build must be strictly greater than every build in the live feed. With "resume", the
# feed may already hold this very build (the appcast landed before a failure), so equal is fine.
check_build_newer() {
    local build="$1" appcast="$2" mode="${3:-new}" max
    max="$(max_sparkle_version "$appcast")"
    if [[ "$mode" == resume ]]; then
        (( build >= max )) || guard_error "build $build is older than build $max in the live appcast" || return 1
    else
        (( build > max )) || guard_error "build $build is not newer than build $max in the live appcast (bump VERSION)" || return 1
    fi
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Compare a published file with the local one. Prints "absent" (404, safe to upload) or
# "same" (already published, identical bytes). Fails when the remote bytes differ, because
# versioned archives are served as immutable, or when the URL can't be checked.
remote_state() {
    local url="$1" file="$2" tmp code
    tmp="$(mktemp)"
    code="$(curl -sS -o "$tmp" -w '%{http_code}' "$url")" || { rm -f "$tmp"; guard_error "could not check $url"; return 1; }
    case "$code" in
        404) rm -f "$tmp"; echo absent ;;
        200)
            if [[ "$(sha256_of "$tmp")" == "$(sha256_of "$file")" ]]; then rm -f "$tmp"; echo same
            else rm -f "$tmp"; guard_error "$url is already published with different bytes; never overwrite an immutable archive (bump the version, or use --resume with the original build)"; return 1
            fi ;;
        *) rm -f "$tmp"; guard_error "$url answered HTTP $code; can't tell whether it is published"; return 1 ;;
    esac
}

# After an upload: the served Content-Length and sha256 must match the local file.
check_served() {
    local url="$1" file="$2" length tmp
    length="$(curl -fsSI "$url" | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r')"
    [[ "$length" == "$(stat -f %z "$file")" ]] || guard_error "$url serves $length bytes, the local file has $(stat -f %z "$file")" || return 1
    tmp="$(mktemp)"
    curl -fsS -o "$tmp" "$url" || { rm -f "$tmp"; guard_error "could not download $url"; return 1; }
    [[ "$(sha256_of "$tmp")" == "$(sha256_of "$file")" ]] || { rm -f "$tmp"; guard_error "$url serves different bytes than $file"; return 1; }
    rm -f "$tmp"
}

# --- Signing identity ---------------------------------------------------------------------------------

# The PEM of the Keychain certificate with SHA-1 $1.
cert_pem() {
    security find-certificate -a -Z -p | awk -v h="$1" '
        /^SHA-1 hash:/ { take = (toupper($3) == toupper(h)) }
        take && /BEGIN CERTIFICATE/ { on = 1 }
        on { print } on && /END CERTIFICATE/ { exit }'
}

# Before building: the pinned identity exists, is a G2 Developer ID, and is not about to expire.
check_identity() {
    local sha1="$1" pem
    security find-identity -v -p codesigning | grep -qi "$sha1" \
        || guard_error "no valid codesigning identity with SHA-1 $sha1 in the Keychain" || return 1
    pem="$(cert_pem "$sha1")"
    [[ -n "$pem" ]] || guard_error "certificate $sha1 not found by security find-certificate" || return 1
    openssl x509 -noout -issuer <<<"$pem" | tr -d ' ' | grep -q "OU=G2" \
        || guard_error "certificate $sha1 is not issued by the G2 Developer ID CA" || return 1
    openssl x509 -noout -checkend $(( 30 * 86400 )) <<<"$pem" >/dev/null \
        || guard_error "certificate $sha1 expires within 30 days ($(openssl x509 -noout -enddate <<<"$pem"))" || return 1
    openssl x509 -noout -checkend $(( 90 * 86400 )) <<<"$pem" >/dev/null \
        || echo "warning: certificate $sha1 expires within 90 days ($(openssl x509 -noout -enddate <<<"$pem"))" >&2
    return 0
}

# One signed item: leaf SHA-1 == $2, issued by the G2 CA, team $3, a secure timestamp, and
# (unless $4 is "noruntime") the hardened runtime.
check_signature() {
    local item sha1="$2" team="$3" runtime="${4:-runtime}" dir info leaf
    # Absolute, because the certificates are extracted from inside a temp directory.
    item="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    dir="$(mktemp -d)"
    info="$(codesign -dvvv "$item" 2>&1)" || { rm -rf "$dir"; guard_error "$item is not signed"; return 1; }
    (cd "$dir" && codesign -d --extract-certificates "$item" >/dev/null 2>&1)
    if [[ ! -f "$dir/codesign0" ]]; then rm -rf "$dir"; guard_error "no certificates in the signature of $item"; return 1; fi
    leaf="$(openssl x509 -inform DER -noout -fingerprint -sha1 -in "$dir/codesign0" | sed 's/.*=//; s/://g')"
    local issuer
    issuer="$(openssl x509 -inform DER -noout -issuer -in "$dir/codesign0" | tr -d ' ')"
    rm -rf "$dir"
    [[ "$(tr a-f A-F <<<"$leaf")" == "$(tr a-f A-F <<<"$sha1")" ]] \
        || guard_error "$item is signed by certificate $leaf, not the pinned $sha1" || return 1
    grep -q "CN=DeveloperIDCertificationAuthority" <<<"$issuer" && grep -q "OU=G2" <<<"$issuer" \
        || guard_error "$item: the signing certificate's issuer is not the G2 Developer ID CA ($issuer)" || return 1
    grep -q "^TeamIdentifier=$team$" <<<"$info" || guard_error "$item: TeamIdentifier is not $team" || return 1
    grep -q "^Timestamp=" <<<"$info" || guard_error "$item has no secure timestamp" || return 1
    if [[ "$runtime" == runtime ]]; then
        grep -q "flags=.*runtime" <<<"$info" || guard_error "$item lacks the hardened runtime" || return 1
    fi
}

# The app and every nested Sparkle helper (framework, Autoupdate, Updater.app).
check_app_signatures() {
    local app="$1" sha1="$2" team="$3" item
    check_signature "$app" "$sha1" "$team" || return 1
    while IFS= read -r item; do
        check_signature "$item" "$sha1" "$team" || return 1
    done < <(find "$app/Contents/Frameworks" \( -name '*.framework' -o -name '*.app' -o \( -type f -name Autoupdate \) \) -not -path '*/Versions/Current/*' 2>/dev/null)
}

# The final artefacts: the app as extracted from the zip and as found in the mounted DMG,
# plus the DMG's own signature. With "notarized": Gatekeeper must see a notarized Developer
# ID app and both staples must validate.
check_artifacts() {
    local zip="$1" dmg="$2" sha1="$3" team="$4" notarized="${5:-notarized}" tmp mnt rc=0
    tmp="$(mktemp -d)"
    ditto -x -k "$zip" "$tmp" || { rm -rf "$tmp"; guard_error "could not extract $zip"; return 1; }
    check_app_signatures "$tmp/Fivebars.app" "$sha1" "$team" || rc=1
    if [[ $rc -eq 0 && "$notarized" == notarized ]]; then
        spctl -a -vv -t exec "$tmp/Fivebars.app" 2>&1 | grep -q "source=Notarized Developer ID" \
            || guard_error "Gatekeeper does not see the zipped app as a notarized Developer ID app" || rc=1
        xcrun stapler validate -q "$tmp/Fivebars.app" >/dev/null 2>&1 || guard_error "the zipped app has no valid staple" || rc=1
    fi
    rm -rf "$tmp"
    [[ $rc -eq 0 ]] || return 1
    check_signature "$dmg" "$sha1" "$team" noruntime || return 1
    mnt="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg" || { rmdir "$mnt"; guard_error "could not mount $dmg"; return 1; }
    check_app_signatures "$mnt/Fivebars.app" "$sha1" "$team" || rc=1
    if [[ $rc -eq 0 && "$notarized" == notarized ]]; then
        spctl -a -vv -t exec "$mnt/Fivebars.app" 2>&1 | grep -q "source=Notarized Developer ID" \
            || guard_error "Gatekeeper does not see the DMG's app as a notarized Developer ID app" || rc=1
    fi
    hdiutil detach -quiet "$mnt" || true
    rmdir "$mnt" 2>/dev/null || true
    [[ $rc -eq 0 ]] || return 1
    if [[ "$notarized" == notarized ]]; then
        xcrun stapler validate -q "$dmg" >/dev/null 2>&1 || guard_error "the DMG has no valid staple" || return 1
    fi
    return 0
}

# Before deleting build/release/<version>/: none of the versioned archive URLs may be published,
# because --resume needs the original files. A 200 always fails. With "strict" (real releases)
# any answer but 404 fails too; otherwise (dry runs, maybe offline) it only warns.
check_unpublished() {
    local mode="$1" url code
    shift
    for url in "$@"; do
        code="$(curl -sS -o /dev/null -I --max-time 20 -w '%{http_code}' "$url" 2>/dev/null)" || code=000
        case "$code" in
            404) ;;
            200) guard_error "$url is already published: use --resume to finish that release (a rebuild would delete the files it needs)"; return 1 ;;
            *)
                if [[ "$mode" == strict ]]; then
                    guard_error "$url answered HTTP $code; can't tell whether $url is published, so build/release is kept"
                    return 1
                fi
                echo "warning: could not check $url (HTTP $code)" >&2 ;;
        esac
    done
}
