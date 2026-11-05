import Foundation

/// Négociation Telnet minimale (RFC 854, 855, 857, 858, 1073, 1091) : écho et « suppress go
/// ahead » du serveur acceptés, type de terminal (xterm-256color) et taille de la fenêtre (NAWS)
/// annoncés ; toute autre option est refusée. Les commandes IAC sont retirées des données reçues.
/// Pur : les octets à renvoyer au serveur sont rendus par chaque appel.
public struct TelnetNegotiator: Sendable {
    public enum Command: UInt8, Sendable {
        case se = 240, nop = 241, dataMark = 242, brk = 243, ip = 244, ao = 245, ayt = 246, ec = 247, el = 248, ga = 249
        case sb = 250, will = 251, wont = 252, `do` = 253, dont = 254, iac = 255
    }

    public enum Option: UInt8, Sendable {
        case binary = 0, echo = 1, suppressGoAhead = 3, status = 5, timingMark = 6, terminalType = 24
        case windowSize = 31, terminalSpeed = 32, linemode = 34, environment = 39
    }

    public static let iac: UInt8 = 255

    /// Type de terminal annoncé (en majuscules, comme le veut la RFC 1091).
    public var terminalType = "XTERM-256COLOR"
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Le serveur fait l'écho : sinon la session affiche elle-même la saisie.
    public private(set) var remoteEcho = false
    public private(set) var suppressGoAhead = false
    public private(set) var binary = false
    /// Le serveur a accepté NAWS : chaque redimensionnement lui est envoyé.
    public private(set) var windowSizeEnabled = false

    private enum State: Sendable { case data, iac, option(Command), subnegotiation, subnegotiationIAC }
    private var state = State.data
    private var subnegotiation: [UInt8] = []
    /// Options que nous avons proposées (WILL) ou demandées (DO), pour ne jamais répondre en boucle.
    private var weWill: Set<UInt8> = []
    private var weDo: Set<UInt8> = []

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
    }

    /// Ouverture : propositions faites d'emblée (comme le client telnet de BSD).
    public mutating func start() -> [UInt8] {
        var out: [UInt8] = []
        out += request(.do, .suppressGoAhead)
        out += request(.will, .terminalType)
        out += request(.will, .windowSize)
        return out
    }

    /// Lit des octets du serveur : données à afficher et réponses à renvoyer.
    public mutating func receive(_ bytes: [UInt8]) -> (data: [UInt8], reply: [UInt8]) {
        var data: [UInt8] = []
        var reply: [UInt8] = []
        data.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .data:
                if byte == Self.iac { state = .iac } else { data.append(byte) }
            case .iac:
                switch byte {
                case Self.iac:
                    data.append(Self.iac)
                    state = .data
                case Command.will.rawValue, Command.wont.rawValue, Command.do.rawValue, Command.dont.rawValue:
                    state = .option(Command(rawValue: byte) ?? .nop)
                case Command.sb.rawValue:
                    subnegotiation.removeAll()
                    state = .subnegotiation
                default:
                    state = .data
                }
            case .option(let command):
                reply += negotiate(command, option: byte)
                state = .data
            case .subnegotiation:
                if byte == Self.iac {
                    state = .subnegotiationIAC
                } else if subnegotiation.count < 512 {
                    subnegotiation.append(byte)
                }
            case .subnegotiationIAC:
                if byte == Command.se.rawValue {
                    reply += handleSubnegotiation()
                    state = .data
                } else {
                    if byte == Self.iac, subnegotiation.count < 512 { subnegotiation.append(Self.iac) }
                    state = .subnegotiation
                }
            }
        }
        return (data, reply)
    }

    /// Nouvelle taille : « IAC SB NAWS » si le serveur l'a acceptée.
    public mutating func resize(columns: Int, rows: Int) -> [UInt8] {
        self.columns = columns
        self.rows = rows
        return windowSizeEnabled ? windowSizeMessage() : []
    }

    /// Octets saisis, prêts pour le réseau : IAC doublé, CR seul suivi de NUL (RFC 854).
    public func encodeOutgoing(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for (index, byte) in bytes.enumerated() {
            out.append(byte)
            if byte == Self.iac { out.append(Self.iac) }
            if byte == 0x0D, !binary {
                let next = index + 1 < bytes.count ? bytes[index + 1] : nil
                if next != 0x0A { out.append(0x00) }
            }
        }
        return out
    }

    /// « IAC BRK » (touche Pause d'un câble console relayé par un serveur de terminaux).
    public static var breakCommand: [UInt8] { [iac, Command.brk.rawValue] }

    // MARK: Négociation

    private mutating func request(_ command: Command, _ option: Option) -> [UInt8] {
        if command == .will { weWill.insert(option.rawValue) } else if command == .do { weDo.insert(option.rawValue) }
        return [Self.iac, command.rawValue, option.rawValue]
    }

    private mutating func negotiate(_ command: Command, option byte: UInt8) -> [UInt8] {
        let option = Option(rawValue: byte)
        switch command {
        case .will:
            // Le serveur propose de faire quelque chose de son côté.
            switch option {
            case .echo, .suppressGoAhead, .binary:
                setRemote(option, on: true)
                if weDo.contains(byte) { return [] }
                weDo.insert(byte)
                return [Self.iac, Command.do.rawValue, byte]
            default:
                return [Self.iac, Command.dont.rawValue, byte]
            }
        case .wont:
            setRemote(option, on: false)
            guard weDo.contains(byte) else { return [] }
            weDo.remove(byte)
            return [Self.iac, Command.dont.rawValue, byte]
        case .do:
            // Le serveur nous demande de faire quelque chose.
            switch option {
            case .terminalType, .suppressGoAhead, .binary:
                if option == .binary { binary = true }
                if weWill.contains(byte) { return [] }
                weWill.insert(byte)
                return [Self.iac, Command.will.rawValue, byte]
            case .windowSize:
                windowSizeEnabled = true
                var out: [UInt8] = []
                if !weWill.contains(byte) {
                    weWill.insert(byte)
                    out += [Self.iac, Command.will.rawValue, byte]
                }
                return out + windowSizeMessage()
            default:
                return [Self.iac, Command.wont.rawValue, byte]
            }
        case .dont:
            if option == .windowSize { windowSizeEnabled = false }
            if option == .binary { binary = false }
            guard weWill.contains(byte) else { return [] }
            weWill.remove(byte)
            return [Self.iac, Command.wont.rawValue, byte]
        default:
            return []
        }
    }

    private mutating func setRemote(_ option: Option?, on: Bool) {
        switch option {
        case .echo: remoteEcho = on
        case .suppressGoAhead: suppressGoAhead = on
        case .binary: binary = on
        default: break
        }
    }

    private func handleSubnegotiation() -> [UInt8] {
        // TTYPE SEND (1) : on répond TTYPE IS (0) suivi du type.
        guard subnegotiation.count >= 2, subnegotiation[0] == Option.terminalType.rawValue, subnegotiation[1] == 1 else { return [] }
        return [Self.iac, Command.sb.rawValue, Option.terminalType.rawValue, 0] + Array(terminalType.utf8)
            + [Self.iac, Command.se.rawValue]
    }

    private func windowSizeMessage() -> [UInt8] {
        let width = UInt16(clamping: columns), height = UInt16(clamping: rows)
        var payload: [UInt8] = []
        for byte in [UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)] {
            payload.append(byte)
            if byte == Self.iac { payload.append(Self.iac) }
        }
        return [Self.iac, Command.sb.rawValue, Option.windowSize.rawValue] + payload + [Self.iac, Command.se.rawValue]
    }
}
