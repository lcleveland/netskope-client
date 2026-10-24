// The Netskope client, as a DankMaterialShell dank-bar widget.
//
// It replaces Netskope's own GTK tray icon (stagentui) and covers its menu through
// stAgentCli: status, Enable/Disable Netskope Client, Save Logs, View Blocked
// Events, plus the configuration and the version the icon's About shows. Not
// covered, because stAgentCli has no command for them: Advanced Debugging,
// Re-authenticate Private Access (IdP tenants only) and Endpoint SD-WAN.
//
// What it adds is a switch for the stagentd daemon itself. The client's own
// Disable can be forbidden by the tenant (allowClientDisabling=false), and then the
// only way out of the traffic path is stopping the daemon. That is
// `systemctl start|stop stagentd`, which the module's polkit rule allows without a
// password, and whose stop also clears the steering routes (ExecStopPost).
//
// stAgentCli is run from /opt and without LD_LIBRARY_PATH: the daemon rejects IPC
// peers whose /proc/<pid>/exe is not on its /opt allowlist, or whose
// LD_LIBRARY_PATH holds /nix/store paths.
import QtQuick
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    readonly property string version: "@version@"
    readonly property var cli: ["env", "-u", "LD_LIBRARY_PATH", "/opt/netskope/stagent/stAgentCli"]

    property bool daemonUp: false
    property string statusText: ""
    property string paText: ""
    // The user the client is enrolled as, from show-config's "User Email:".
    property string userEmail: ""
    property bool everChecked: false
    property bool busy: false
    property string actionTitle: ""
    property string actionOutput: ""

    // show-status wording is not documented, so read it loosely and show it verbatim.
    readonly property bool clientEnabled: daemonUp && /enabled/i.test(statusText) && !/disabled/i.test(statusText)

    readonly property color statusColor: {
        if (!daemonUp)
            return Theme.surfaceVariantText;
        return clientEnabled ? Theme.success : Theme.warning;
    }

    readonly property string summary: {
        if (!everChecked)
            return "Checking…";
        if (!daemonUp)
            return "Off — the daemon is stopped";
        return clientEnabled ? "On" : "Daemon running, client not enabled";
    }

    // stAgentCli opens every run with this line.
    function clean(text) {
        return text.split("\n").filter(l => l.trim() !== "start process...").join("\n").trim();
    }

    function refresh() {
        if (!statusProcess.running)
            statusProcess.running = true;
    }

    function run(title, command) {
        if (busy)
            return;
        busy = true;
        actionTitle = title;
        actionOutput = "";
        actionProcess.command = command;
        actionProcess.running = true;
    }

    function setDaemon(on) {
        run(on ? "Starting the daemon" : "Stopping the daemon", ["systemctl", on ? "start" : "stop", "stagentd.service"]);
    }

    // Private Processes rather than Proc.runCommand: DankBar makes one instance per
    // bar, and Proc collapses same-id commands onto one callback.
    Process {
        id: statusProcess

        command: ["sh", "-c", "if systemctl is-active --quiet stagentd.service; then echo up; " + root.cli.join(" ") + " show-status 2>&1; echo @@NEXT@@; " + root.cli.join(" ") + " show-pa 2>&1; echo @@NEXT@@; " + root.cli.join(" ") + " show-config 2>&1; else echo down; fi"]
        running: false

        stdout: StdioCollector {
            id: statusOutput
        }

        onExited: {
            const text = statusOutput.text;
            const parts = text.substring(text.indexOf("\n") + 1).split("@@NEXT@@");
            root.daemonUp = text.startsWith("up");
            root.statusText = root.daemonUp ? root.clean(parts[0]) : "";
            root.paText = root.daemonUp ? root.clean(parts[1] ?? "") : "";
            const email = /User Email:\s*(\S+)/.exec(parts[2] ?? "");
            root.userEmail = root.daemonUp && email ? email[1] : "";
            root.everChecked = true;
        }
    }

    Process {
        id: actionProcess

        running: false

        stdout: StdioCollector {
            id: actionStdout
        }
        stderr: StdioCollector {
            id: actionStderr
        }

        onExited: exitCode => {
            root.busy = false;
            const out = root.clean(actionStdout.text + "\n" + actionStderr.text);
            root.actionOutput = out !== "" ? out : (exitCode === 0 ? "Done." : "Failed (exit " + exitCode + ").");
            root.refresh();
        }
    }

    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    popoutWidth: 460
    popoutHeight: 560

    horizontalBarPill: Component {
        DankIcon {
            name: root.daemonUp ? "vpn_lock" : "vpn_key_off"
            size: root.iconSize
            color: root.statusColor
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: root.daemonUp ? "vpn_lock" : "vpn_key_off"
            size: root.iconSize
            color: root.statusColor
        }
    }

    popoutContent: Component {
        FocusScope {
            width: parent ? parent.width : 0
            implicitHeight: mainContent.implicitHeight

            PopoutComponent {
                id: mainContent

                width: parent.width
                headerText: "Netskope"
                detailsText: root.summary
                showCloseButton: false

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    DToggle {
                        width: parent.width
                        text: "Netskope daemon"
                        description: "Stopping it takes this machine out of the traffic path"
                        checked: root.daemonUp
                        enabled: !root.busy
                        onToggled: checked => root.setDaemon(checked)
                    }

                    StyledRect {
                        width: parent.width
                        height: statusColumn.implicitHeight + Theme.spacingM * 2
                        color: Theme.surfaceContainerHigh
                        radius: Theme.cornerRadius
                        visible: root.daemonUp

                        Column {
                            id: statusColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingXS

                            Row {
                                spacing: Theme.spacingS
                                visible: root.userEmail !== ""

                                DankIcon {
                                    name: "person"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: root.userEmail
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                width: parent.width
                                text: root.statusText
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                text: root.paText
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.WordWrap
                                visible: text !== ""
                            }
                        }
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: root.daemonUp

                        DButton {
                            text: root.clientEnabled ? "Disable client" : "Enable client"
                            iconName: root.clientEnabled ? "pause_circle" : "play_circle"
                            enabled: !root.busy
                            onClicked: root.run(text, root.cli.concat([root.clientEnabled ? "disable" : "enable"]))
                        }

                        DButton {
                            text: "Save logs"
                            iconName: "download"
                            enabled: !root.busy
                            // The client writes the bundle to ~/Desktop, as its tray does.
                            onClicked: root.run(text, ["sh", "-c", "mkdir -p \"$HOME/Desktop\" && exec " + root.cli.join(" ") + " save-logs"])
                        }

                        DButton {
                            text: "Blocked events"
                            iconName: "block"
                            enabled: !root.busy
                            onClicked: root.run(text, root.cli.concat(["show-blocked-event"]))
                        }

                        DButton {
                            text: "Configuration"
                            iconName: "settings"
                            enabled: !root.busy
                            onClicked: root.run(text, root.cli.concat(["show-config"]))
                        }
                    }

                    // Output of the last action. Selectable, so it can be copied.
                    StyledRect {
                        width: parent.width
                        height: Math.min(220, actionText.implicitHeight + Theme.spacingS * 2 + actionLabel.implicitHeight)
                        color: Theme.surfaceContainerHigh
                        radius: Theme.cornerRadius
                        clip: true
                        visible: root.actionTitle !== ""

                        StyledText {
                            id: actionLabel

                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingS
                            text: root.busy ? root.actionTitle + "…" : root.actionTitle
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }

                        TextEdit {
                            id: actionText

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: actionLabel.bottom
                            anchors.margins: Theme.spacingS
                            text: root.actionOutput
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: "Netskope Client " + root.version
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
        }
    }
}
