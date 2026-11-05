import NetScopeCore
import SwiftUI

/// Feuille « Modifier la liste » de l'outil « État des services » : services suivis, ajout d'un
/// service personnalisé, accès Microsoft Graph (secret au Trousseau).
struct ServiceCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var svc = SvcStore.shared

    // Nouveau service
    @State private var name = ""
    @State private var format: SvcFeedFormat = .statuspage
    @State private var feedURL = ""
    @State private var pageURL = ""
    @State private var endpoints = ""
    @State private var addError: String?

    // Microsoft Graph
    @State private var tenant = ""
    @State private var client = ""
    @State private var secret = ""
    @State private var graphMessage: (String, Tone)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Services suivis").font(Theme.panelTitle)
                Spacer()
                Button("Rétablir la liste intégrée") { svc.resetCatalog() }
                    .buttonStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    serviceList
                    addForm
                    graphForm
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Terminé") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 640)
        .onAppear {
            tenant = svc.graphTenant
            client = svc.graphClient
        }
    }

    // MARK: Liste

    /// Catalogue regroupé par catégorie. Première case : suivi dans le catalogue (tous les sites) ;
    /// case « Ici » : suivi au site actif (note 53, ex. réseaux sociaux bloqués exprès à un site).
    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ToolFieldLabel("Catalogue (\(svc.catalogEnabledServices.count) sur \(svc.services.count) suivis)")
                Spacer()
                Text("Ici\u{00A0}= site «\u{00A0}\(svc.siteName)\u{00A0}»")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(svc.categories, id: \.self) { category in
                    categoryHeader(category)
                    ForEach(svc.services.filter { $0.category == category }) { service in
                        serviceRow(service)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        }
    }

    private func categoryHeader(_ category: String) -> some View {
        let state = svc.categoryState(category)
        return HStack(spacing: 8) {
            Text(category.uppercased())
                .font(.system(size: 10, weight: .bold)).kerning(0.4)
                .foregroundStyle(Theme.textSecondary)
            if state == .partial {
                Text("en partie ici").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { state != .hidden }, set: { svc.setCategory(category, visible: $0) })) {
                Text("Ici").font(Theme.caption)
            }
            .toggleStyle(.checkbox)
            .help("Suivre ou masquer toute la catégorie au site «\u{00A0}\(svc.siteName)\u{00A0}»")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.panelMuted)
    }

    private func serviceRow(_ service: SvcService) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { service.isEnabled }, set: { svc.setEnabled($0, for: service.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Suivi dans le catalogue (tous les sites)")
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                Text("\(service.format.label) · \(service.endpointHosts.joined(separator: ", "))")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if service.isCustom {
                Button(role: .destructive) { svc.remove(service.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Retirer ce service")
            }
            Toggle(isOn: Binding(get: { svc.isVisibleHere(service) }, set: { svc.setVisibleHere($0, for: service.id) })) {
                Text("Ici").font(Theme.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(!service.isEnabled)
            .help("Suivi au site «\u{00A0}\(svc.siteName)\u{00A0}»")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Ajout

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Ajouter un service")
            HStack(spacing: 8) {
                TextField("Nom (ex. Fournisseur Internet)", text: $name).textFieldStyle(.roundedBorder)
                Picker("Format", selection: $format) {
                    ForEach(SvcFeedFormat.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if format != .none {
                TextField("Adresse de la page d’état lue (https://status.exemple.com/api/v2/summary.json)", text: $feedURL)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            }
            TextField("Page officielle à ouvrir (facultatif)", text: $pageURL)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
            TextField("Adresses clés testées d’ici (portail.exemple.com, api.exemple.com)", text: $endpoints)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
            HStack {
                if let addError {
                    Text(addError).font(Theme.small).foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Ajouter") {
                    addError = svc.addCustom(name: name, format: format, feedURL: feedURL, pageURL: pageURL, endpoints: endpoints)
                    if addError == nil {
                        name = ""; feedURL = ""; pageURL = ""; endpoints = ""
                    }
                }
                .buttonStyle(.secondary)
            }
        }
    }

    // MARK: Microsoft Graph

    private var graphForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolFieldLabel("Microsoft 365 · santé du locataire (Microsoft Graph)")
                RegPill(text: svc.graphSecretSet ? "Configuré" : "Non configuré", tone: svc.graphSecretSet ? .success : .neutral)
            }
            Text("Facultatif. Une application inscrite dans Entra ID avec la permission d’application ServiceHealth.Read.All donne l’état détaillé de votre locataire (Exchange, Teams, SharePoint, OneDrive). Sans configuration, NetScope lit la page publique et n’appelle jamais Graph. Le secret est enregistré au Trousseau.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Locataire (contoso.onmicrosoft.com ou GUID)", text: $tenant)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(12))
                TextField("ID de l’application (client)", text: $client)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(12))
            }
            SecureField(svc.graphSecretSet ? "Secret enregistré au Trousseau (laisser vide pour le garder)" : "Secret client", text: $secret)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let (message, tone) = graphMessage {
                    Text(message).font(Theme.small).foregroundStyle(tone.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if svc.graphSecretSet || !svc.graphTenant.isEmpty {
                    Button("Retirer l’accès", role: .destructive) {
                        svc.clearGraph()
                        tenant = ""; client = ""; secret = ""
                        graphMessage = ("Accès retiré, secret effacé du Trousseau.", .neutral)
                    }
                    .buttonStyle(.secondary)
                }
                Button("Enregistrer") {
                    if let error = svc.saveGraph(tenant: tenant, client: client, secret: secret) {
                        graphMessage = (error, .critical)
                    } else {
                        secret = ""
                        graphMessage = (svc.graphSecretSet ? "Enregistré\u{00A0}; Microsoft 365 sera lu par Graph." : "Enregistré\u{00A0}; ajouter le secret pour activer Graph.", .success)
                    }
                }
                .buttonStyle(.secondary)
                .disabled(tenant.isEmpty || client.isEmpty)
            }
        }
    }
}
