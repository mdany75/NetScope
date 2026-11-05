#!/bin/bash
#
# build.sh — compile « NetScope », assemble l'application et son image disque
# d'installation dans build/.
#
# Usage : ./build.sh [--install]     (depuis n'importe quel dossier courant)
#         --install : remplace aussi /Applications/NetScope.app
#
# Variables d'environnement :
#   SIGN_IDENTITY="-"   signature ad hoc même si un certificat est présent
#   SKIP_NOTARIZE=1     signe avec le certificat mais ne notarise pas (essai rapide)
#   NOTARY_PROFILE=nom  profil de « xcrun notarytool store-credentials » (défaut : notarisation)
#
# Étapes :
#   1. swift build -c release --product NetScope
#   2. icône : Resources/AppIcon.icns est régénérée seulement si elle manque
#      ou si scripts/make-icon.swift est plus récent
#   3. assemblage de « NetScope.app » dans un dossier temporaire (avec Resources/oui.tsv,
#      la base des fabricants)
#   4. signature : Developer ID et runtime durci (ad hoc sans certificat), avec les droits de
#      Resources/NetScope.entitlements (localisation), puis vérification
#   5. installation dans /Applications, seulement avec --install
#   6. image disque « build/NetScope.dmg » (application + raccourci vers Applications)
#   7. signature de l'image disque, notarisation chez Apple, agrafage du ticket
#
# build/ est ignoré par git ; l'image disque est publiée en Release GitHub (voir CLAUDE.md).
#
# Le script s'arrête avec un code non nul à la première erreur.
# Il n'écrit que dans le dossier du projet (build/, .build/, Resources/AppIcon.icns)
# et dans un dossier temporaire supprimé à la fin.

set -euo pipefail

APP_NAME="NetScope"
PRODUCT="NetScope"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_DIR="${ROOT_DIR}/scripts"

RESOURCES_DIR="${ROOT_DIR}/Resources"
INFO_PLIST="${RESOURCES_DIR}/Info.plist"
ICON_SCRIPT="${SCRIPT_DIR}/make-icon.swift"
ICON_FILE="${RESOURCES_DIR}/AppIcon.icns"
LPROJ_DIR="${RESOURCES_DIR}/fr.lproj"
OUI_FILE="${RESOURCES_DIR}/oui.tsv"
# Droits de l'application (runtime durci) : localisation, exigée par macOS pour lire le nom
# des réseaux Wi-Fi. Sans ce droit, macOS refuse la localisation sans afficher de fenêtre.
ENTITLEMENTS="${RESOURCES_DIR}/NetScope.entitlements"

DIST_DIR="${ROOT_DIR}/build"

WORK_DIR=""
STAGE_DIR=""
INSTALL=0
for arg in "$@"; do
    case "${arg}" in
        --install) INSTALL=1 ;;
        *) printf 'Option inconnue : %s (seule option : --install)\n' "${arg}" >&2; exit 1 ;;
    esac
done

step() { printf '\n==> %s\n' "$1"; }
die()  { printf 'Erreur : %s\n' "$1" >&2; exit 1; }

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
    if [[ -n "${STAGE_DIR}" && -d "${STAGE_DIR}" ]]; then
        rm -rf "${STAGE_DIR}"
    fi
}
trap cleanup EXIT

# --- Vérifications préalables -------------------------------------------------

[[ -f "${ROOT_DIR}/Package.swift" ]] || die "Package.swift introuvable dans ${ROOT_DIR}"
[[ -f "${INFO_PLIST}" ]]             || die "fichier manquant : ${INFO_PLIST}"
[[ -f "${ICON_SCRIPT}" ]]            || die "fichier manquant : ${ICON_SCRIPT}"
[[ -s "${OUI_FILE}" ]]               || die "base des fabricants manquante : ${OUI_FILE} (python3 -I scripts/make-oui.py, voir CLAUDE.md)"

for tool in swift iconutil codesign plutil hdiutil ditto security xcrun spctl; do
    command -v "${tool}" >/dev/null 2>&1 || die "outil introuvable : ${tool}"
done

plutil -lint "${INFO_PLIST}" >/dev/null || die "Info.plist invalide : ${INFO_PLIST}"
[[ -f "${ENTITLEMENTS}" ]] || die "fichier manquant : ${ENTITLEMENTS}"
plutil -lint "${ENTITLEMENTS}" >/dev/null || die "fichier de droits invalide : ${ENTITLEMENTS}"

# --- Signature et notarisation ------------------------------------------------
#
# Avec le certificat « Developer ID Application » dans le trousseau, le code est signé avec
# le runtime durci, puis ce qui est distribué est notarisé chez Apple : il s'ouvre sans
# avertissement sur n'importe quel Mac, et macOS conserve les autorisations accordées d'une
# version à l'autre (l'identité ne change plus). Sans certificat (autre machine), signature
# ad hoc et pas de notarisation.

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarisation}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    SIGN_ARGS=(--sign -)
    NOTARIZE=0; NOTARIZE_WHY="signature ad hoc, aucun certificat Developer ID"
elif [[ "${SKIP_NOTARIZE:-0}" != "0" ]]; then
    SIGN_ARGS=(--options runtime --timestamp --sign "${SIGN_IDENTITY}")
    NOTARIZE=0; NOTARIZE_WHY="SKIP_NOTARIZE=1"
else
    SIGN_ARGS=(--options runtime --timestamp --sign "${SIGN_IDENTITY}")
    NOTARIZE=1; NOTARIZE_WHY=""
fi

# sign_code OPTIONS… CHEMIN : signe, puis vérifie. Le serveur d'horodatage d'Apple renvoie
# parfois une heure décalée de quelques minutes, que « codesign --verify --strict » refuse
# (« timestamps differ ») : on signe alors de nouveau, jusqu'à trois fois.
sign_code() {
    local attempt
    for attempt in 1 2 3; do
        codesign --force "$@"
        codesign --verify --deep --strict "${@:$#}" && return 0
        printf 'Vérification de la signature refusée (essai %s/3), nouvelle signature…\n' "${attempt}" >&2
        sleep 2
    done
    die "signature impossible à vérifier : ${@:$#}"
}

# notarize_file FICHIER : soumet l'archive ou l'image disque à Apple et attend le verdict
# (quelques minutes).
notarize_file() {
    local file="$1" output id
    step "Notarisation de « $(basename "${file}") » (profil « ${NOTARY_PROFILE} »)"
    if ! output="$(xcrun notarytool submit "${file}" --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1)"; then
        printf '%s\n' "${output}" >&2
        die "notarisation impossible : session verrouillée (le profil n'est lisible qu'écran déverrouillé) ou profil « ${NOTARY_PROFILE} » absent (xcrun notarytool store-credentials)"
    fi
    printf '%s\n' "${output}"
    if ! grep -q '^ *status: Accepted' <<< "${output}"; then
        id="$(sed -n 's/^ *id: //p' <<< "${output}" | head -n 1)"
        [[ -z "${id}" ]] || xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        die "notarisation refusée par Apple (détail ci-dessus)"
    fi
}

# finalize_dmg FICHIER : signe l'image disque, la notarise, agrafe le ticket et vérifie que
# Gatekeeper l'accepte. Sans notarisation, dit seulement pourquoi.
finalize_dmg() {
    local dmg="$1"
    if [[ "${NOTARIZE}" -eq 0 ]]; then
        step "Image disque non notarisée (${NOTARIZE_WHY}) : avertissement de macOS sur un autre Mac"
        return 0
    fi
    sign_code --timestamp --sign "${SIGN_IDENTITY}" "${dmg}"
    notarize_file "${dmg}"
    step "Agrafage du ticket et vérification Gatekeeper"
    xcrun stapler staple "${dmg}"
    spctl -a -t open --context context:primary-signature -vv "${dmg}"
}

# --- 1. Compilation -----------------------------------------------------------

step "Compilation (release)"
swift build -c release --product "${PRODUCT}" --package-path "${ROOT_DIR}"

BIN_DIR="$(swift build -c release --product "${PRODUCT}" --package-path "${ROOT_DIR}" --show-bin-path)"
BINARY="${BIN_DIR}/${PRODUCT}"
[[ -f "${BINARY}" && -x "${BINARY}" ]] || die "exécutable introuvable après la compilation : ${BINARY}"

# --- 2. Icône -----------------------------------------------------------------

if [[ ! -f "${ICON_FILE}" || "${ICON_SCRIPT}" -nt "${ICON_FILE}" ]]; then
    step "Génération de l'icône"
    TMP_BASE="${TMPDIR:-/tmp}"
    WORK_DIR="$(mktemp -d "${TMP_BASE%/}/build-icon.XXXXXX")"
    ICONSET_DIR="${WORK_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"

    swift "${ICON_SCRIPT}" "${ICONSET_DIR}"

    for name in \
        icon_16x16.png   icon_16x16@2x.png \
        icon_32x32.png   icon_32x32@2x.png \
        icon_128x128.png icon_128x128@2x.png \
        icon_256x256.png icon_256x256@2x.png \
        icon_512x512.png icon_512x512@2x.png
    do
        [[ -s "${ICONSET_DIR}/${name}" ]] || die "image d'icône manquante : ${name}"
    done

    # Écrit d'abord à côté, puis remplace : pas de fichier .icns à moitié écrit.
    iconutil -c icns -o "${WORK_DIR}/AppIcon.icns" "${ICONSET_DIR}"
    [[ -s "${WORK_DIR}/AppIcon.icns" ]] || die "iconutil n'a pas produit AppIcon.icns"
    mv -f "${WORK_DIR}/AppIcon.icns" "${ICON_FILE}"
else
    step "Icône à jour (${ICON_FILE})"
fi

# --- 3. Assemblage ------------------------------------------------------------

step "Assemblage de « ${APP_NAME}.app »"

mkdir -p "${DIST_DIR}"

# L'application est assemblée et signée hors du projet : un dossier synchronisé (iCloud Drive)
# ajoute des attributs étendus qui font échouer la signature.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-app.XXXXXX")"
STAGE_APP="${STAGE_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${STAGE_APP}/Contents"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources/fr.lproj"

cp "${BINARY}" "${CONTENTS_DIR}/MacOS/${PRODUCT}"
chmod 755 "${CONTENTS_DIR}/MacOS/${PRODUCT}"

cp "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

cp "${ICON_FILE}" "${CONTENTS_DIR}/Resources/AppIcon.icns"

# Base des fabricants (registre IEEE), lue par OUIDatabase depuis les ressources de l'application.
cp "${OUI_FILE}" "${CONTENTS_DIR}/Resources/oui.tsv"
[[ -s "${CONTENTS_DIR}/Resources/oui.tsv" ]] || die "oui.tsv absent de l'application"

# Notes de version (Réglages › Mises à jour : historique complet et résumé de chaque version).
cp "${ROOT_DIR}/CHANGELOG.md" "${CONTENTS_DIR}/Resources/CHANGELOG.md"
[[ -s "${CONTENTS_DIR}/Resources/CHANGELOG.md" ]] || die "CHANGELOG.md absent de l'application"

# fr.lproj : sa présence suffit pour que les panneaux système s'affichent en français.
if [[ -d "${LPROJ_DIR}" ]]; then
    find "${LPROJ_DIR}" -maxdepth 1 -type f ! -name '.*' \
        -exec cp {} "${CONTENTS_DIR}/Resources/fr.lproj/" \;
fi
if [[ ! -f "${CONTENTS_DIR}/Resources/fr.lproj/InfoPlist.strings" ]]; then
    printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n' "${APP_NAME}" "${APP_NAME}" \
        > "${CONTENTS_DIR}/Resources/fr.lproj/InfoPlist.strings"
fi

plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null || die "Info.plist invalide dans l'application"

# --- 4. Signature -------------------------------------------------------------

step "Signature (${SIGN_IDENTITY})"
# Les attributs étendus (informations du Finder, etc.) font échouer codesign.
xattr -cr "${STAGE_APP}"
# Les droits s'appliquent à l'application seulement (pas à l'image disque).
sign_code --entitlements "${ENTITLEMENTS}" "${SIGN_ARGS[@]}" "${STAGE_APP}"

# --- 5. Installation (avec --install) -----------------------------------------

if [[ "${INSTALL}" -eq 1 ]]; then
    step "Installation dans /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "${STAGE_APP}" "/Applications/${APP_NAME}.app"
    codesign --verify --deep --strict "/Applications/${APP_NAME}.app"
    touch "/Applications/${APP_NAME}.app"
fi

# --- 6. Image disque d'installation --------------------------------------------

step "Image disque « ${APP_NAME}.dmg »"
DMG_FILE="${DIST_DIR}/${APP_NAME}.dmg"
DMG_ROOT="${STAGE_DIR}/dmg"
mkdir -p "${DMG_ROOT}"
ditto "${STAGE_APP}" "${DMG_ROOT}/${APP_NAME}.app"
# Raccourci pour l'installation : on glisse l'application sur « Applications ».
ln -s /Applications "${DMG_ROOT}/Applications"

# Créée dans le dossier temporaire, puis déplacée : jamais d'image à moitié écrite dans build/.
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -fs HFS+ -format UDZO \
    -ov -quiet "${STAGE_DIR}/${APP_NAME}.dmg"
hdiutil verify -quiet "${STAGE_DIR}/${APP_NAME}.dmg"

# --- 7. Notarisation ----------------------------------------------------------

finalize_dmg "${STAGE_DIR}/${APP_NAME}.dmg"
mv -f "${STAGE_DIR}/${APP_NAME}.dmg" "${DMG_FILE}"

step "Terminé"
printf '%s\n' "${DMG_FILE}"
