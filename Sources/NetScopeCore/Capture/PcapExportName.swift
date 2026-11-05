import Foundation

/// Note 78 : nom du fichier .pcap écrit pour « Ouvrir dans Wireshark » (et proposé à
/// l'enregistrement) : « capture-en7-2026-11-04-1021.pcap ». Le nom de la source (interface ou
/// fichier ouvert) est nettoyé : ni barre oblique, ni espace, ni extension en double.
public enum PcapExportName {
    public static func fileName(source: String, date: Date, calendar: Calendar = .current) -> String {
        var base = source
        for suffix in [".pcapng", ".pcap", ".cap"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var cleaned = String(base.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if cleaned.isEmpty { cleaned = "netscope" }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "capture-\(cleaned.prefix(40))-\(stamp).pcap"
    }
}
