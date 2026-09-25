import SwiftUI

struct SynologyLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var host: String = ""
    @State private var portStr: String = "5000"
    @State private var isHTTPS: Bool = false
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var otpCode: String = ""

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard

                        serverConfigCard

                        accountCard

                        actionButtons

                        instructionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("群晖 NAS 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundStyle(Color.atmusicAmber)
                }
            }
            .onAppear {
                loadCurrentValues()
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 52, height: 52)
                .background {
                    Circle()
                        .fill(Color.atmusicAmber.opacity(0.16))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Synology Audio Station")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)

                HStack(spacing: 6) {
                    Circle()
                        .fill(synology.isLoggedIn ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(synology.isLoggedIn ? "已连接并授权" : "未连接")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(synology.isLoggedIn ? Color.green : Color.atmusicComment)
                }
            }

            Spacer()
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var serverConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("服务器网络设置")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            VStack(spacing: 10) {
                HStack {
                    Text("地址")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("例如 192.168.1.100 或 nas.me.com", text: $host)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("端口")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("5000", text: $portStr)
                        .font(ATMusicFont.appFont(14))
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                Toggle(isOn: $isHTTPS) {
                    Text("启用 HTTPS (SSL)")
                        .font(ATMusicFont.appFont(14))
                }
                .padding(.horizontal, 4)
                .onChange(of: isHTTPS) { _, enabled in
                    if enabled && portStr == "5000" {
                        portStr = "5001"
                    } else if !enabled && portStr == "5001" {
                        portStr = "5000"
                    }
                }
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DSM 登录凭据")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            VStack(spacing: 10) {
                HStack {
                    Text("账号")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("群晖用户名", text: $account)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("密码")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    SecureField("群晖密码", text: $password)
                        .font(ATMusicFont.appFont(14))
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("OTP")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("双重验证码 (若开启了2FA)", text: $otpCode)
                        .font(ATMusicFont.appFont(14))
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await performLogin() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(synology.isLoggedIn ? "保存并重新登录" : "登录并连接")
                        .font(ATMusicFont.appFont(15, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.atmusicAmber, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isLoading || host.isEmpty || account.isEmpty)
            .buttonStyle(GlassPressButtonStyle())

            if synology.isLoggedIn {
                Button(role: .destructive) {
                    Task {
                        await synology.logout()
                        ToastCenter.shared.show("已退出群晖登录")
                    }
                } label: {
                    Text("断开连接并登出")
                        .font(ATMusicFont.appFont(14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.red)
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("使用说明：")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Text("1. 请确保群晖 NAS 已经安装并启动了官方 Audio Station 套件。\n2. 如在家庭局域网内，建议填写 NAS 内网 IP（如 192.168.x.x，默认端口 5000）。\n3. 如在外网访问，请填写 DDNS 域名或公网 IP，并确认路由器已转发相应端口。\n4. 登录成功后，即可在「音乐库」中直接浏览和播放 NAS 中的全部歌曲与歌单。")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func loadCurrentValues() {
        host = synology.host
        portStr = "\(synology.port)"
        isHTTPS = synology.isHTTPS
        account = synology.account
        password = synology.savedPassword
    }

    private func performLogin() async {
        guard let p = Int(portStr), p > 0 else {
            errorMessage = "端口号格式错误"
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            try synology.saveConfiguration(host: host, port: p, isHTTPS: isHTTPS, account: account, password: password)
            try await synology.login(otpCode: otpCode.isEmpty ? nil : otpCode)
            isLoading = false
            ToastCenter.shared.show("群晖 NAS 连接成功！")
            dismiss()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            ToastCenter.shared.show("连接失败: \(error.localizedDescription)")
        }
    }
}
