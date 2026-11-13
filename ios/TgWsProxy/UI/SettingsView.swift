import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var proxy: ProxyViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var secretCopied = false
    @State private var refreshingDomains = false
    @State private var refreshError = false

    var body: some View {
        Form {
            Section("Язык".tgLoc) {
                Picker(selection: languageBinding) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(verbatim: "\(lang.flag)  \(lang.title)").tag(lang)
                    }
                } label: {
                    Label("Язык приложения".tgLoc, systemImage: "globe")
                }
                .pickerStyle(.menu)
            }

            Section("Локальный прокси".tgLoc) {
                HStack {
                    Text("Адрес:".tgLoc)
                    TextField("127.0.0.1", text: $proxy.configuration.bindAddress)
                        .multilineTextAlignment(.trailing)
                        .proxyTextInputBehavior()
                }
                HStack {
                    Text("Порт:".tgLoc)
                    TextField("1443", value: $proxy.configuration.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .proxyNumberInputBehavior()
                }
                HStack {
                    Text("Размер пула:".tgLoc)
                    Picker("Размер пула:".tgLoc, selection: $proxy.configuration.poolSize) {
                        ForEach(ProxyConfiguration.allowedPoolSizes, id: \.self) {
                            Text(String($0)).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .disabled(proxy.configurationLocked)

            Section("Cloudflare".tgLoc) {
                Toggle("Использовать Cloudflare".tgLoc, isOn: $proxy.configuration.cloudflareEnabled)
                TextField("Свои CF-домены через запятую".tgLoc, text: $proxy.configuration.cloudflareDomain)
                    .proxyTextInputBehavior()
                TextField("Свои Workers через запятую".tgLoc, text: $proxy.configuration.workerDomains)
                    .proxyTextInputBehavior()
                Toggle("CF через порт 80".tgLoc, isOn: $proxy.configuration.disableSecure)
                Text("Порт 80 может помочь в мобильных сетях. Выключено: WSS через 443.".tgLoc)
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("\("Домены CF Worker".tgLoc) (\(proxy.cloudflareDomains.count))") {
                    if proxy.cloudflareDomains.isEmpty {
                        Text("Список пуст".tgLoc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(proxy.cloudflareDomains, id: \.self) { domain in
                            HStack {
                                Image(systemName: "cloud.fill")
                                    .foregroundStyle(.blue)
                                Text(domain)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = domain
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button {
                    refreshingDomains = true
                    Task {
                        refreshError = !(await proxy.refreshCloudflareDomains())
                        refreshingDomains = false
                    }
                } label: {
                    Label(
                        refreshingDomains ? "Обновление…".tgLoc : "Обновить список Workers".tgLoc,
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(refreshingDomains)
                if refreshError { Text("Не удалось обновить список. Сохранён предыдущий.".tgLoc).foregroundStyle(.orange) }
            }
            .disabled(proxy.configurationLocked)

            Section("Telegram DC".tgLoc) {
                TextField(
                    "Переопределения адресов".tgLoc,
                    text: $proxy.configuration.dcAddresses,
                    axis: .vertical
                )
                .lineLimit(3...8)
                Text("Пустое значение использует адреса из Rust upstream.".tgLoc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(proxy.configurationLocked)

            Section("Секрет".tgLoc) {
                TextField("Домен FakeTLS (необязательно)".tgLoc, text: $proxy.configuration.fakeTLSDomain)
                    .proxyTextInputBehavior()
                    .disabled(proxy.configurationLocked)
                Button {
                    UIPasteboard.general.string = proxy.configuration.telegramSecret
                    secretCopied = true
                    Haptics.notify(.success)
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        secretCopied = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.blue)
                        Text(proxy.configuration.telegramSecret)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: secretCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(secretCopied ? .green : .secondary)
                    }
                }
                .buttonStyle(.plain)
                Text(secretCopied ? "Секрет скопирован" : "Нажмите, чтобы скопировать Telegram-секрет")
                    .font(.caption)
                    .foregroundStyle(secretCopied ? .green : .secondary)
                Button("Скопировать ссылку подключения".tgLoc) {
                    UIPasteboard.general.string = proxy.telegramURL()?.absoluteString
                }
                Text("В форке Telegram укажите адрес, порт и secret из этих настроек вручную.".tgLoc)
                    .font(.caption).foregroundStyle(.secondary)
                Button("Сгенерировать новый".tgLoc) {
                    proxy.regenerateSecret()
                }
                .disabled(proxy.configurationLocked)
            }

            Section("Внешний вид".tgLoc) {
                Picker("Тема".tgLoc, selection: Binding(
                    get: { settings.theme },
                    set: { settings.theme = $0 }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Акцент".tgLoc).font(.callout)
                    HStack(spacing: 14) {
                        ForEach(AccentChoice.allCases, id: \.self) { choice in
                            Circle()
                                .fill(choice.color)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if settings.accent == choice {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(.white.opacity(settings.accent == choice ? 0.9 : 0), lineWidth: 2)
                                }
                                .onTapGesture {
                                    Haptics.impact(.light)
                                    settings.accent = choice
                                }
                        }
                    }
                }
                Toggle("Liquid Glass".tgLoc, isOn: $settings.liquidGlass)
            }

            Section("Поведение".tgLoc) {
                Toggle("График трафика".tgLoc, isOn: $settings.showTrafficChart)
                Toggle("Авто-старт при запуске".tgLoc, isOn: $settings.autoStart)
                Toggle("Авто-переподключение".tgLoc, isOn: $settings.reconnect)
                Toggle("Уведомления".tgLoc, isOn: $settings.notifications)
                Toggle("Вибрация".tgLoc, isOn: $settings.haptics)
            }

            if settings.restartRequired {
                Section {
                    Button("Перезапустить интерфейс".tgLoc) {
                        settings.restartInterface()
                    }
                }
            }

            Section("Расширенные настройки".tgLoc) {
                Stepper(String(format: "Буфер: %lld КБ".tgLoc, proxy.configuration.bufferSizeKB),
                        value: $proxy.configuration.bufferSizeKB, in: 4...4096, step: 4)
                Toggle("Тестовые DC".tgLoc, isOn: $proxy.configuration.forceTestDC)
                Toggle("PROXY protocol v1".tgLoc, isOn: $proxy.configuration.proxyProtocol)
                Text("PROXY protocol требует совместимого промежуточного клиента. Для прямого подключения Telegram оставьте выключенным.".tgLoc)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(proxy.configurationLocked)

            Section("Диагностика".tgLoc) {
                Toggle("Подробные логи Rust".tgLoc, isOn: $proxy.configuration.verboseLogging)
                    .disabled(proxy.configurationLocked)
            }

        }
        .scrollContentBackground(.hidden)
        .onValueChange(of: settings.notifications) { on in
            if on { NotificationManager.requestAuthorization() }
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settings.language },
            set: { newValue in
                guard settings.language != newValue else { return }
                Haptics.impact(.light)
                withAnimation(.snappy) { settings.language = newValue }
            }
        )
    }
}

private extension View {
    @ViewBuilder
    func proxyTextInputBehavior() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func proxyNumberInputBehavior() -> some View {
#if os(iOS)
        keyboardType(.numberPad)
#else
        self
#endif
    }
}
