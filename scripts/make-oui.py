#!/usr/bin/env python3
"""make-oui.py — convertit le registre IEEE (MA-L, MA-M, MA-S) en Resources/oui.tsv.

Usage :
    python3 -I scripts/make-oui.py <dossier des csv> Resources/oui.tsv
    python3 -I scripts/make-oui.py --self-test

Le dossier contient oui.csv (MA-L, 24 bits), mam.csv (MA-M, 28 bits) et oui36.csv
(MA-S, 36 bits), téléchargés depuis https://standards-oui.ieee.org/. Les fichiers sont lus
comme du texte CSV, jamais exécutés.

Sortie : une ligne « HEX<TAB>Nom » par préfixe (6, 7 ou 9 chiffres hexadécimaux en
majuscules), triée, précédée d'un commentaire « # Registre IEEE …, converti le AAAA-MM-JJ ».

Les règles de nettoyage des noms sont écrites deux fois, ici et dans
Sources/NetScopeCore/Hardware/OUIRegistry.swift ; les deux suivent la même liste
d'exemples (scripts/oui-name-examples.tsv), vérifiée par --self-test et par NetScopeSelfTest.
Toute modification se fait des deux côtés.
"""

import csv
import datetime
import os
import sys

FILES = (("oui.csv", 6), ("mam.csv", 7), ("oui36.csv", 9))
HEADER = ["Registry", "Assignment", "Organization Name", "Organization Address"]

# Noms ignorés : blocs non attribués à un fabricant.
IGNORED = {"private", "ieee registration authority"}

# Suffixes juridiques retirés en fin de nom (clé : minuscules, sans points ni virgules).
LEGAL_SUFFIXES = {
    "inc", "incorporated", "corp", "corporation", "corporate", "co", "company", "ltd", "ltda",
    "limited", "llc", "lp", "llp", "plc", "gmbh", "mbh", "ag", "kg", "sa", "sas", "sarl", "spa",
    "srl", "sl", "slu", "bv", "nv", "oy", "oyj", "ab", "as", "aps", "asa", "pte", "pty", "kk",
    "sdn", "bhd", "cv", "de", "jsc", "ooo", "zao", "sro", "sp", "z", "o", "ou", "ulc", "pvt",
}

# Après l'un de ces suffixes, « Technology » est retiré aussi (« Technology Co., Ltd »).
COMPANY_WORDS = {"co", "coltd", "colimited", "company", "corp", "corporation"}

# Après l'un de ces suffixes, « Private » est retiré aussi (« Private Limited », Inde).
LIMITED_WORDS = {"limited", "ltd"}

# Mots laissés seuls en fin de nom une fois les suffixes retirés (« Science and Technology Co. »).
DANGLING_WORDS = {"and", "&", "und", "et"}

# Mots dont la casse est imposée quand un nom tout en majuscules est remis en casse normale.
FIXED_WORDS = {
    "hp": "HP", "hpe": "HPE", "ibm": "IBM", "lg": "LG", "nec": "NEC", "zte": "ZTE", "avm": "AVM",
    "tcl": "TCL", "nxp": "NXP", "byd": "BYD", "asus": "ASUS", "asustek": "ASUS", "d-link": "D-Link",
    "tp-link": "TP-Link", "usa": "USA", "uk": "UK", "it": "IT", "ip": "IP", "tv": "TV", "av": "AV",
    "ai": "AI", "iot": "IoT", "led": "LED", "rf": "RF", "gps": "GPS", "lte": "LTE", "pc": "PC",
    "ii": "II", "iii": "III", "iv": "IV", "3d": "3D", "oem": "OEM", "abb": "ABB", "jvc": "JVC",
    "bmw": "BMW", "rca": "RCA", "ntt": "NTT", "kddi": "KDDI", "sk": "SK", "kt": "KT",
}

# Mots courts écrits en minuscules au milieu d'un nom remis en casse normale.
SMALL_WORDS = {"and", "of", "the", "for", "de", "du", "des", "la", "le", "et", "und", "y", "a", "an"}

# Noms courts des grands fabricants (clé : nom nettoyé en minuscules), cohérents avec la table
# intégrée de NetScope.
ALIASES = {
    "apple": "Apple",
    "cisco systems": "Cisco", "cisco": "Cisco", "cisco-linksys": "Linksys",
    "cisco meraki": "Cisco Meraki", "meraki": "Cisco Meraki",
    "dell": "Dell", "dell technologies": "Dell",
    "lenovo": "Lenovo", "lenovo mobile communication technology": "Lenovo",
    "motorola mobility llc, a lenovo": "Motorola", "lcfc(hefei) electronics": "Lenovo",
    "hewlett packard": "HP", "hewlett-packard company": "HP", "hewlett-packard": "HP",
    "hp": "HP", "hp inc": "HP",
    "hewlett packard enterprise": "HPE", "aruba, a hewlett packard enterprise company": "HPE Aruba",
    "aruba networks": "HPE Aruba",
    "brother industries": "Brother", "fortinet": "Fortinet",
    "ubiquiti networks": "Ubiquiti", "ubiquiti": "Ubiquiti",
    "hangzhou hikvision digital": "Hikvision", "hikvision": "Hikvision",
    "zhejiang dahua": "Dahua", "zhejiang dahua technologyco": "Dahua", "zhejiang dahua technology": "Dahua", "dahua": "Dahua",
    "synology": "Synology", "qnap systems": "QNAP",
    "raspberry pi foundation": "Raspberry Pi", "raspberry pi trading": "Raspberry Pi",
    "raspberry pi (trading)": "Raspberry Pi",
    "samsung electronics": "Samsung", "samsung electro-mechanics(thailand)": "Samsung",
    "samsung electro mechanics": "Samsung",
    "intel corporate": "Intel", "intel": "Intel",
    "espressif": "Espressif", "espressif systems": "Espressif",
    "google": "Google", "nest labs": "Google Nest",
    "amazon technologies": "Amazon", "amazon.com services": "Amazon", "amazon": "Amazon",
    "sonos": "Sonos",
    "microsoft": "Microsoft", "microsoft mobile": "Microsoft",
    "vmware": "VMware",
    "xiaomi communications": "Xiaomi", "beijing xiaomi mobile software": "Xiaomi",
    "beijing xiaomi electronics": "Xiaomi", "xiaomi electronics": "Xiaomi",
    "huawei technologies": "Huawei", "huawei device": "Huawei", "huawei symantec": "Huawei",
    "zte": "ZTE", "tp-link technologies": "TP-Link", "tp-link": "TP-Link",
    "tp-link systems": "TP-Link", "tp-link corporation": "TP-Link",
    "asustek computer": "ASUS", "netgear": "Netgear", "mikrotikls": "MikroTik",
    "routerboard.com": "MikroTik",
    "xerox": "Xerox", "canon": "Canon", "seiko epson": "Epson",
    "yealink(xiamen) network": "Yealink", "yealink network": "Yealink",
    "polycom": "Poly", "axis communications": "Axis", "brightsign": "BrightSign",
    "parallels": "Parallels", "lg electronics": "LG", "lg electronics (mobile communications)": "LG",
    "lg innotek": "LG Innotek", "sony": "Sony", "sony interactive entertainment": "Sony",
    "nintendo": "Nintendo", "texas instruments": "Texas Instruments",
    "juniper networks": "Juniper", "extreme networks": "Extreme Networks",
    "ruckus wireless": "Ruckus", "guangdong oppo mobile telecommunications": "OPPO",
    "vivo mobile communication": "vivo", "honor device": "Honor",
    "hon hai precision ind": "Foxconn", "hon hai precision industry": "Foxconn",
    "d-link international": "D-Link", "d-link": "D-Link",
    "zyxel communications": "Zyxel", "eero": "eero", "avm audiovisuelles marketing und computersysteme": "AVM",
    "avm": "AVM", "roku": "Roku", "philips lighting bv": "Philips Hue", "signify netherlands": "Philips Hue",
    "nvidia": "NVIDIA", "realtek semiconductor": "Realtek", "liteon": "Lite-On",
    "murata manufacturing": "Murata", "azurewave": "AzureWave",
    "new h3c technologies": "H3C", "arcadyan": "Arcadyan", "sagemcom broadband": "Sagemcom",
    "ring": "Ring", "ecobee": "ecobee", "nokia": "Nokia", "nokia shanghai bell": "Nokia",
    "ricoh": "Ricoh", "kyocera": "Kyocera", "konica minolta": "Konica Minolta",
    "lexmark international": "Lexmark", "zebra technologies": "Zebra",
    "grandstream networks": "Grandstream", "mitel networks": "Mitel", "avaya": "Avaya",
    "palo alto networks": "Palo Alto Networks", "sonicwall": "SonicWall", "watchguard technologies": "WatchGuard",
    "super micro computer": "Supermicro", "american megatrends": "AMI",
}


def _key(word):
    """Mot en minuscules sans points ni virgules (« Co.,Ltd. » → « coltd »)."""
    return word.lower().replace(".", "").replace(",", "")


def _is_suffix(word):
    key = _key(word)
    if key in LEGAL_SUFFIXES:
        return True
    # « Co.,Ltd », « Co.Ltd », « S.p.A. », « A/S », « Sp. z o.o. » collés.
    if key in {"coltd", "colimited", "coinc", "cokg", "a/s", "ag&co", "oo"}:
        return True
    # Région entre parenthèses en fin de nom : « (Shenzhen) », « (Thailand) ».
    return len(word) > 2 and word.startswith("(") and word.endswith(")")


def _space_after_commas(text):
    """« Co.,Ltd » → « Co., Ltd » : une espace après une virgule suivie d'une lettre."""
    out = []
    for index, char in enumerate(text):
        out.append(char)
        if char == "," and index + 1 < len(text) and text[index + 1].isalpha():
            out.append(" ")
    return "".join(out)


def _strip_trailing(text):
    return text.rstrip(" ,.;:-&/")


def _title_word(word):
    """Majuscule en début de mot (et après « - », « / », « ( », « . »), minuscules ensuite."""
    out = []
    previous_alnum = False
    for char in word:
        if char.isalpha():
            out.append(char.lower() if previous_alnum else char.upper())
            previous_alnum = True
        else:
            out.append(char)
            previous_alnum = char in "0123456789'"
    return "".join(out)


def _has_vowel(word):
    return any(c in "aeiouyAEIOUY" for c in word)


def _normalize_case(words):
    result = []
    for index, word in enumerate(words):
        key = word.lower().strip(",.()")
        if key in FIXED_WORDS:
            fixed = FIXED_WORDS[key]
            result.append(word.lower().replace(key, fixed, 1))
        elif index > 0 and key in SMALL_WORDS:
            result.append(word.lower())
        elif len(key) <= 3 and key.isalpha() and not _has_vowel(key):
            result.append(word)  # sigle : « NXP », « BRK »
        else:
            result.append(_title_word(word))
    return result


def clean_name(raw):
    """Nom court lisible d'une organisation du registre, ou None pour une ligne à ignorer."""
    text = " ".join(_space_after_commas(raw).split())
    if not text or text.lower() in IGNORED:
        return None
    original = _strip_trailing(text)
    words = text.split(" ")
    # Suffixes juridiques en fin de nom ; « Technology Co. » aussi.
    while len(words) > 1:
        last = words[-1]
        if _is_suffix(last):
            removed = _key(last)
            words.pop()
            if removed in COMPANY_WORDS and len(words) > 1 and _key(words[-1]) == "technology":
                words.pop()
            elif removed in LIMITED_WORDS and len(words) > 1 and _key(words[-1]) == "private":
                words.pop()
            continue
        if _key(last) in DANGLING_WORDS:
            words.pop()
            continue
        stripped = _strip_trailing(last)
        if stripped != last:
            if stripped:
                words[-1] = stripped
            else:
                words.pop()
            continue
        break
    words = [w for w in words if w]
    name = _strip_trailing(" ".join(words))
    if not name:
        name = original
    if not any(c.islower() for c in name) and any(c.isalpha() for c in name):
        name = " ".join(_normalize_case(name.split(" ")))
    alias = ALIASES.get(name.lower())
    if alias:
        return alias
    return name


def read_registry(path, digits):
    """Lignes (préfixe, nom) d'un fichier CSV du registre."""
    rows = []
    with open(path, encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header is None or [h.strip() for h in header[:4]] != HEADER:
            raise SystemExit(f"Erreur : en-tête inattendu dans {path}")
        for row in reader:
            if len(row) < 3:
                continue
            prefix = row[1].strip().upper()
            if len(prefix) != digits or any(c not in "0123456789ABCDEF" for c in prefix):
                continue
            name = clean_name(row[2])
            if name:
                rows.append((prefix, name))
    return rows


def convert(folder, date):
    table = {}
    for filename, digits in FILES:
        path = os.path.join(folder, filename)
        rows = read_registry(path, digits)
        if filename == "oui.csv" and len(rows) < 20000:
            raise SystemExit(f"Erreur : {path} ne compte que {len(rows)} préfixes")
        for prefix, name in rows:
            table[prefix] = name
    lines = [f"# Registre IEEE MA-L/MA-M/MA-S, converti le {date}"]
    lines += [f"{prefix}\t{table[prefix]}" for prefix in sorted(table)]
    return "\n".join(lines) + "\n", len(table)


def self_test():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "oui-name-examples.tsv")
    failures = 0
    count = 0
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            raw, expected = line.split("\t")
            got = clean_name(raw) or ""
            count += 1
            if got != expected:
                failures += 1
                print(f"ÉCHEC : {raw!r} → {got!r}, attendu {expected!r}")
    print(f"{count} exemples, {failures} en échec.")
    return 1 if failures else 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        print("    python3 -I scripts/make-oui.py <dossier des csv> Resources/oui.tsv", file=sys.stderr)
        return 2
    folder, output = argv[1], argv[2]
    text, count = convert(folder, datetime.date.today().isoformat())
    temporary = output + ".tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, output)
    print(f"{output} : {count} préfixes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
