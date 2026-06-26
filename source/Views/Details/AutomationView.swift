import SwiftUI
import AutoMountyModel
import AppKit

struct AutomationView: View {
    @Binding var profile: MountProfile
    
    var body: some View {
        Section(LocalizedStringKey("Automation")) {
            if profile.automations.isEmpty {
                Text(LocalizedStringKey("No automation tasks configured"))
                    .italic()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
            } else {
                ForEach($profile.automations) { $automation in
                    AutomationRow(automation: $automation) {
                        if let index = profile.automations.firstIndex(where: { $0.id == automation.id }) {
                            profile.automations.remove(at: index)
                        }
                    }
                }
            }
            
            Button(action: {
                var newAuto = AutomationConfig()
                newAuto.type = .shell
                profile.automations.append(newAuto)
            }) {
                Label(LocalizedStringKey("Add Task"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct AutomationRow: View {
    @Binding var automation: AutomationConfig
    let onDelete: () -> Void
    
    @State private var showingEventPicker = false
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header: Type | Run On | Status | Actions
                HStack(spacing: 12) {
                    Picker("", selection: $automation.type) {
                        ForEach(AutomationType.allCases) { type in
                            Text(type.localizedName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .help(LocalizedStringKey("Select the type of automation"))
                    
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Run On:"))
                            .font(.callout)
                            .foregroundColor(.secondary)
                        
                        Button(action: { showingEventPicker.toggle() }) {
                            HStack {
                                if automation.events.isEmpty {
                                    Text(LocalizedStringKey("Select..."))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(automation.events.map { $0.localizedName }.joined(separator: ", "))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .help(LocalizedStringKey("Select when this automation should run"))
                        .popover(isPresented: $showingEventPicker) {
                            VStack(alignment: .leading) {
                                ForEach(ScriptEvent.allCases) { event in
                                    EventToggle(event: event, selectedEvents: $automation.events)
                                }
                            }
                            .padding()
                        }
                    }
                    
                    Spacer()
                    
                    Toggle(LocalizedStringKey("Enabled"), isOn: $automation.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(LocalizedStringKey("Enable or disable this task"))
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(LocalizedStringKey("Delete this task"))
                }
                
                Divider()
                
                // Details Form
                FormGrid {
                    if automation.type == .wol {
                        wolFields
                    } else {
                        scriptFields
                    }
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    var wolFields: some View {
        LabeledContent("MAC Address") {
            TextField("", text: $automation.macAddress,prompt: Text("00:11:22:33:44:55"))
                .textFieldStyle(.roundedBorder)
        }
        .help("Target MAC address for Wake-on-LAN")
        
        LabeledContent("Broadcast") {
            TextField("", text: $automation.broadcastAddress,prompt: Text("255.255.255.255"))
                .textFieldStyle(.roundedBorder)
        }
        .help("Broadcast address for the magic packet")
        
        LabeledContent("Wait") {
            HStack(spacing: 4) {
                TextField("", text: Binding(
                    get: { String(format: "%.0f", automation.waitTime) },
                    set: { if let value = Double($0) { automation.waitTime = value } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                
                Text(LocalizedStringKey("seconds"))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    var scriptFields: some View {
        LabeledContent(automation.type == .app ? "App Path" : "Script Path") {
            HStack {
                TextField("", text: $automation.path, prompt: Text(automation.type == .app ? "e.g. /Applications/MyApp.app" : "e.g. /path/to/script.sh"))
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if automation.type == .app {
                        panel.allowedContentTypes = [.application]
                    }
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            automation.path = url.path
                        }
                    }
                }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(LocalizedStringKey("Browse for file..."))
            }
        }
        .help(automation.type == .app ? "Path to the application (.app)" : "Path to the script or executable")
        
        if automation.type == .shell {
            LabeledContent("Arguments") {
                TextField("", text: $automation.arguments, prompt: Text("-v --force"))
                    .textFieldStyle(.roundedBorder)
            }
            .help("Command line arguments passed to the script")
        }
    }
}

struct EventToggle: View {
    let event: ScriptEvent
    @Binding var selectedEvents: Set<ScriptEvent>
    
    var body: some View {
        Toggle(event.localizedName, isOn: Binding(
            get: { selectedEvents.contains(event) },
            set: { isOn in
                if isOn {
                    selectedEvents.insert(event)
                } else {
                    selectedEvents.remove(event)
                }
            }
        ))
        .padding(.vertical, 2)
    }
}
