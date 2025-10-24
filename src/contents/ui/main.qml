import QtQuick
import QtQuick.Layouts
import org.kde.kwin
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import "js/core.mjs" as Core
import "js/utils.mjs" as Utils
import "components" as Components

Item {
    id: root
    
    property int highlightedZone: -1
    property bool shown: false
    property bool moving: false
    property bool moved: false
    property bool resizing: false
    property var clientArea: ({})
    property var cachedClientArea: ({})
    property var displaySize: ({})
    property int currentLayout: 0
    property var screenLayouts: ({})
    property var activeScreen: null
    property var config: ({})
    property bool showZoneOverlay: config.zoneOverlayShowWhen == 0
    property var errors: []

    PlasmaCore.Dialog {

        // api documentation
        // https://api.kde.org/frameworks/plasma-framework/html/classPlasmaQuick_1_1Dialog.html
        // https://api.kde.org/frameworks/plasma-framework/html/classPlasma_1_1Types.html
        // https://develop.kde.org/docs/getting-started/kirigami/style-colors/

        id: mainDialog

        // properties
        

        title: "KZones Overlay"
        location: PlasmaCore.Types.Desktop
        type: PlasmaCore.Dialog.OnScreenDisplay
        backgroundHints: PlasmaCore.Types.NoBackground
        flags: Qt.BypassWindowManagerHint | Qt.FramelessWindowHint | Qt.Popup
        hideOnWindowDeactivate: true
        visible: false
        outputOnly: true
        opacity: 1
        width: displaySize.width
        height: displaySize.height

        function show() {
            // show OSD
            console.log("KZones: Show");
            root.shown = true;
            mainDialog.visible = true;
            mainDialog.setWidth(Workspace.virtualScreenSize.width);
            mainDialog.setHeight(Workspace.virtualScreenSize.height);
            refreshClientArea();
        }

        function hide() {
            // hide OSD
            root.shown = false;
            mainDialog.visible = false;
            zoneSelector.expanded = false;
            zoneSelector.near = false;
            root.highlightedZone = -1;
            showZoneOverlay = config.zoneOverlayShowWhen == 0;
        }

        Components.ColorHelper {
            id: colorHelper
        }

        Components.Shortcuts {
            onCycleLayouts: {
                currentLayout = Utils.setCurrentLayout(screenLayouts, (currentLayout + 1) % config.layouts.length);
                root.highlightedZone = -1;
                osdDbus.exec(config.trackLayoutPerScreen ? `${config.layouts[currentLayout].name} (${Workspace.activeScreen.name})` : config.layouts[currentLayout].name);
            }

            onCycleLayoutsReversed: {
                currentLayout = Utils.setCurrentLayout(screenLayouts, (currentLayout - 1 + config.layouts.length) % config.layouts.length);
                root.highlightedZone = -1;
                osdDbus.exec(config.trackLayoutPerScreen ? `${config.layouts[currentLayout].name} (${Workspace.activeScreen.name})` : config.layouts[currentLayout].name);
            }

            onMoveActiveWindowToNextZone: {
                const client = Workspace.activeWindow;
                if (client.zone == -1) moveClientToClosestZone(client);
                const zonesLength = config.layouts[currentLayout].zones.length;
                moveClientToZone(client, (client.zone + 1) % zonesLength);
            }

            onMoveActiveWindowToPreviousZone: {
                const client = Workspace.activeWindow;
                if (client.zone == -1) moveClientToClosestZone(client);
                const zonesLength = config.layouts[currentLayout].zones.length;
                moveClientToZone(client, (client.zone - 1 + zonesLength) % zonesLength);
            }

            onToggleZoneOverlay: {
                if (!config.enableZoneOverlay) {
                    osdDbus.exec("Zone overlay is disabled");
                }
                else if (moving) {
                    showZoneOverlay = !showZoneOverlay;
                }
                else {
                    osdDbus.exec("The overlay can only be shown while moving a window");
                }
            }

            onSwitchToNextWindowInCurrentZone: {
                switchWindowInZone(Workspace.activeWindow.zone, Workspace.activeWindow.layout);
            }

            onSwitchToPreviousWindowInCurrentZone: {
                switchWindowInZone(Workspace.activeWindow.zone, Workspace.activeWindow.layout, true);
            }

            onMoveActiveWindowToZone: {
                moveClientToZone(Workspace.activeWindow, zone);
            }

            onActivateLayout: {
                if (layout <= config.layouts.length - 1) {
                    currentLayout = Utils.setCurrentLayout(screenLayouts, layout);
                    root.highlightedZone = -1;
                    osdDbus.exec(config.trackLayoutPerScreen ? `${config.layouts[currentLayout].name} (${Workspace.activeScreen.name})` : config.layouts[currentLayout].name);
                } else {
                    osdDbus.exec(`Layout ${layout + 1} does not exist`);
                }
            }

            onMoveActiveWindowUp: {
                moveClientToNeighbour(Workspace.activeWindow, "up");
            }

            onMoveActiveWindowDown: {
                moveClientToNeighbour(Workspace.activeWindow, "down");
            }

            onMoveActiveWindowLeft: {
                moveClientToNeighbour(Workspace.activeWindow, "left");
            }

            onMoveActiveWindowRight: {
                moveClientToNeighbour(Workspace.activeWindow, "right");
            }

            onSnapActiveWindow: {
                moveClientToClosestZone(Workspace.activeWindow);
            }

            onSnapAllWindows: {
                moveAllClientsToClosestZone();
            }
        }

        Component.onCompleted: {
            console.log("Loading script (" + Qt.resolvedUrl("./main.qml") + ")");
            Core.init(KWin, Workspace);
            Core.registerQMLComponent("root", root);
            Core.loadConfig();

            // refresh client area
            refreshClientArea();

            // match all clients to zones and connect signals
            for (let i = 0; i < Workspace.stackingOrder.length; i++) {
                Utils.matchZone(Workspace.stackingOrder[i], currentLayout, clientArea);
                connectSignals(Workspace.stackingOrder[i]);
            }
        }

        Item {
            id: mainItem
            property alias repeaterLayout: repeaterLayout

            // main polling timer
            Timer {
                id: timer

                triggeredOnStart: true
                interval: config.pollingRate
                running: root.shown && moving
                repeat: true

                onTriggered: {
                    refreshClientArea();

                    let hoveringZone = -1;

                    // zone overlay
                    const currentZones = mainItem.repeaterLayout.itemAt(currentLayout)
                    if (config.enableZoneOverlay && showZoneOverlay && !zoneSelector.expanded) {
                        currentZones.repeater.model.forEach((zone, zoneIndex) => {
                            if (Utils.isHovering(currentZones.repeater.itemAt(zoneIndex).children[config.zoneOverlayHighlightTarget])) {
                                hoveringZone = zoneIndex;
                            }
                        });
                    }

                    // zone selector
                    if (config.enableZoneSelector) {
                        if (!zoneSelector.animating && zoneSelector.expanded) {
                            zoneSelector.repeater.model.forEach((layout, layoutIndex) => {
                                const layoutItem = zoneSelector.repeater.itemAt(layoutIndex);
                                layout.zones.forEach((zone, zoneIndex) => {
                                    const zoneItem = layoutItem.children[zoneIndex];
                                    if (Utils.isHovering(zoneItem)) {
                                        hoveringZone = zoneIndex;
                                        currentLayout = Utils.setCurrentLayout(screenLayouts, layoutIndex);
                                    }
                                });
                            });
                        }
                        // set zoneSelector expansion state
                        zoneSelector.expanded = Utils.isHovering(zoneSelector) && (Workspace.cursorPos.y - clientArea.y) >= 0;
                        // set zoneSelector near state
                        const triggerDistance = config.zoneSelectorTriggerDistance * 50 + 25;
                        zoneSelector.near = (Workspace.cursorPos.y - clientArea.y) < zoneSelector.y + zoneSelector.height + triggerDistance;
                    }

                    // edge snapping
                    if (config.enableEdgeSnapping) {
                        const triggerDistance = (config.edgeSnappingTriggerDistance + 1) * 10;
                        if (Workspace.cursorPos.x <= clientArea.x + triggerDistance || Workspace.cursorPos.x >= clientArea.x + clientArea.width - triggerDistance || Workspace.cursorPos.y <= clientArea.y + triggerDistance || Workspace.cursorPos.y >= clientArea.y + clientArea.height - triggerDistance) {
                            const padding = config.layouts[currentLayout].padding || 0;
                            const halfPadding = padding/2;
                            currentZones.repeater.model.forEach((zone, zoneIndex) => {
                                const zoneItem = currentZones.repeater.itemAt(zoneIndex);
                                const itemGlobal = zoneItem.mapToGlobal(Qt.point(0, 0));
                                let zoneGeometry = {
                                    x: itemGlobal.x - padding/2,
                                    y: itemGlobal.y - padding/2,
                                    width: zoneItem.width + padding,
                                    height: zoneItem.height + padding
                                };
                                if(zoneGeometry.x <= halfPadding ) { zoneGeometry.x = 0; zoneGeometry.width += padding; }   //adjust most left edge
                                if(zoneGeometry.y <= halfPadding ) { zoneGeometry.y = 0; zoneGeometry.height += padding; }  //adjust most top edge
                                if(zoneGeometry.x + zoneGeometry.width >= clientArea.width - halfPadding ) {                //adjust most right edge
                                    zoneGeometry.width += halfPadding;
                                }
                                if(zoneGeometry.y + zoneGeometry.height >= clientArea.height - halfPadding ) {              //adjust most bottom edge
                                    zoneGeometry.height += halfPadding;
                                }
                                if (Utils.isPointInside(Workspace.cursorPos.x, Workspace.cursorPos.y, zoneGeometry)) {
                                    hoveringZone = zoneIndex;
                                }
                            });
                        }
                    }

                    // if hovering zone changed from the last frame
                    if (hoveringZone != root.highlightedZone) {
                        Utils.log("Highlighting zone " + hoveringZone + " in layout " + currentLayout);
                        root.highlightedZone = hoveringZone;
                    }

                }
            }

            DBusCall {
                id: osdDbus

                service: "org.kde.plasmashell"
                path: "/org/kde/osdService"
                method: "showText"

                function exec(text, icon = "preferences-desktop-virtual") {
                    if (!config.showOsdMessages) return;
                    this.arguments = [icon, text];
                    this.call();
                }
            }

            Item {
                x: clientArea.x || 0
                y: clientArea.y || 0
                width: clientArea.width || 0
                height: clientArea.height || 0
                clip: true

                Components.Debug {
                    info: ({
                        activeWindow: {
                            caption: Workspace.activeWindow?.caption,
                            resourceClass: Workspace.activeWindow?.resourceClass?.toString(),
                            frameGeometry: {
                                x: Workspace.activeWindow?.frameGeometry?.x,
                                y: Workspace.activeWindow?.frameGeometry?.y,
                                width: Workspace.activeWindow?.frameGeometry?.width,
                                height: Workspace.activeWindow?.frameGeometry?.height
                            },
                            zone: Workspace.activeWindow?.zone
                        },
                        highlightedZone: root.highlightedZone,
                        moving: moving,
                        resizing: resizing,
                        oldGeometry: Workspace.activeWindow?.oldGeometry,
                        activeScreen: activeScreen?.name,
                        currentLayout: currentLayout,
                        screenLayouts: screenLayouts
                    })
                    errors: root.errors
                    config: root.config
                }

                Repeater {
                    id: repeaterLayout
                    model: config.layouts

                    Components.Zones {
                        id: zones
                        config: root.config
                        currentLayout: root.currentLayout
                        highlightedZone: root.highlightedZone
                        layoutIndex: index
                        visible: index == root.currentLayout
                    }
                }

                Components.Selector {
                    id: zoneSelector
                    config: root.config
                    currentLayout: root.currentLayout
                    highlightedZone: root.highlightedZone
                }
            }

            // workspace connection
            Connections {
                target: Workspace

                function onWindowAdded(client) {

                    connectSignals(client);

                    // check if client is in a zone application list
                    config.layouts[currentLayout].zones.forEach((zone, zoneIndex) => {
                        if (zone.applications && zone.applications.includes(client.resourceClass.toString())) {
                            moveClientToZone(client, zoneIndex);
                            return;
                        }
                    });

                    // auto snap to closest zone
                    if (config.autoSnapAllNew && Utils.checkFilter(client)) {
                        moveClientToClosestZone(client);
                    }

                    // check if new window spawns in a zone
                    if (client.zone == undefined || client.zone == -1) Utils.matchZone(client, currentLayout, clientArea);

                }
            }

            // reusable timer
            Timer {
                id: delay

                function setTimeout(callback, timeout) {
                    delay.interval = timeout;
                    delay.repeat = false;
                    delay.triggered.connect(callback);
                    delay.triggered.connect(function release() {
                        delay.triggered.disconnect(callback);
                        delay.triggered.disconnect(release);
                    });
                    delay.start();
                }
            }
        }
    }

    function refreshClientArea() {
        activeScreen = Workspace.activeScreen;
        clientArea = Workspace.clientArea(KWin.FullScreenArea, activeScreen, Workspace.currentDesktop);
        displaySize = Workspace.virtualScreenSize;
        currentLayout = Utils.getCurrentLayout(screenLayouts, currentLayout);
    }

    function switchWindowInZone(zone, layout, reverse) {
        const clientsInZone = Utils.getWindowsInZone(zone, layout);
        if (reverse) clientsInZone.reverse();

        // cycle through clients in zone
        if (clientsInZone.length > 0) {
            const index = clientsInZone.indexOf(Workspace.activeWindow);
            if (index === -1) {
                Workspace.activeWindow = clientsInZone[0];
            } else {
                Workspace.activeWindow = clientsInZone[(index + 1) % clientsInZone.length];
            }
        }
    }

    function moveClientToZone(client, zone) {
        // block abnormal windows from being moved (like plasmashell, docks, etc...)
        if (!Utils.checkFilter(client)) return;

        Utils.log("Moving client " + client.resourceClass.toString() + " to zone " + zone);

        refreshClientArea()
        saveClientProperties(client, zone);

        // move client to zone
        if (zone != -1) {
            const currentZones = repeaterLayout.itemAt(currentLayout)
            const zoneItem = currentZones.repeater.itemAt(zone);
            const itemGlobal = zoneItem.mapToGlobal(Qt.point(0, 0));
            const newGeometry = Qt.rect(Math.round(itemGlobal.x), Math.round(itemGlobal.y), Math.round(zoneItem.width), Math.round(zoneItem.height));
            Utils.log("Moving client " + client.resourceClass.toString() + " to zone " + zone + " with geometry " + JSON.stringify(newGeometry));
            client.setMaximize(false, false);
            client.frameGeometry = newGeometry;
        }
    }

    function saveClientProperties(client, zone) {
        Utils.log("Saving geometry for client " + client.resourceClass.toString());

        // save current geometry
        if (config.rememberWindowGeometries) {
            const geometry = {
                "x": client.frameGeometry.x,
                "y": client.frameGeometry.y,
                "width": client.frameGeometry.width,
                "height": client.frameGeometry.height
            };
            if (zone != -1) {
                if (client.zone == -1) {
                    client.oldGeometry = geometry;
                }
            }
        }

        // save zone
        client.zone = zone;
        client.layout = currentLayout;
        client.desktop = Workspace.currentDesktop;
        client.activity = Workspace.currentActivity;
    }

    function moveClientToClosestZone(client) {
        if (!Utils.checkFilter(client)) return null;

        Utils.log("Moving client " + client.resourceClass.toString() + " to closest zone");

        refreshClientArea();

        const closestZone = Utils.findClosestZone(client, currentLayout, clientArea);

        if (client.zone !== closestZone || client.layout !== currentLayout) {
            moveClientToZone(client, closestZone);
        }
        return closestZone;
    }

    function moveAllClientsToClosestZone() {
        Utils.log("Moving all clients to closest zone");
        let count = 0;
        for (let i = 0; i < Workspace.stackingOrder.length; i++) {
            const client = Workspace.stackingOrder[i];
            if (client.move) continue;
            moveClientToClosestZone(client) && count++;
        }
        Utils.log("Moved " + count + " clients to closest zone");
        return count;
    }

    function moveClientToNeighbour(client, direction) {
        if (!Utils.checkFilter(client)) return null;

        Utils.log("Moving client " + client.resourceClass.toString() + " to neighbour " + direction);

        refreshClientArea();

        const zones = config.layouts[currentLayout].zones;

        if (client.zone === -1 || client.layout !== currentLayout) {
            moveClientToClosestZone(client);
            return client.zone;
        };

        const currentZone = zones[client.zone];
        let targetZoneIndex = -1;

        let minDistance = Infinity;

        for (let i = 0; i < zones.length; i++) {
            if (i === client.zone) continue;

            const zone = zones[i];
            let isNeighbour = false;
            let distance = Infinity;

            switch (direction) {
                case "left":
                    if (zone.x + zone.width <= currentZone.x &&
                        zone.y < currentZone.y + currentZone.height &&
                        zone.y + zone.height > currentZone.y) {
                        isNeighbour = true;
                        distance = currentZone.x - (zone.x + zone.width);
                    }
                    break;
                case "right":
                    if (zone.x >= currentZone.x + currentZone.width &&
                        zone.y < currentZone.y + currentZone.height &&
                        zone.y + zone.height > currentZone.y) {
                        isNeighbour = true;
                        distance = zone.x - (currentZone.x + currentZone.width);
                    }
                    break;
                case "up":
                    if (zone.y + zone.height <= currentZone.y &&
                        zone.x < currentZone.x + currentZone.width &&
                        zone.x + zone.width > currentZone.x) {
                        isNeighbour = true;
                        distance = currentZone.y - (zone.y + zone.height);
                    }
                    break;
                case "down":
                    if (zone.y >= currentZone.y + currentZone.height &&
                        zone.x < currentZone.x + currentZone.width &&
                        zone.x + zone.width > currentZone.x) {
                        isNeighbour = true;
                        distance = zone.y - (currentZone.y + currentZone.height);
                    }
                    break;
            }

            if (isNeighbour && distance < minDistance) {
                minDistance = distance;
                targetZoneIndex = i;
            }
        }
        if (targetZoneIndex !== -1) {
            moveClientToZone(client, targetZoneIndex);
        } else if(!config.trackLayoutPerScreen) {
            const toScreenMap = {
                left: "slotWindowToPrevScreen",
                right: "slotWindowToNextScreen",
                up: "slotWindowToAboveScreen",
                down: "slotWindowToBelowScreen"
            };
            if (Workspace[toScreenMap[direction]]) {
                const isVerticalAxis = direction === "up" || direction === "down";
                const specularZone = Utils.findClientSpecularZone(client, currentLayout, clientArea, isVerticalAxis);
                Workspace[toScreenMap[direction]]();
                moveClientToZone(client, specularZone);
            }
        }
        return targetZoneIndex;
    }

    function connectSignals(client) {

        if (!Utils.checkFilter(client)) return;

        Utils.log("Connecting signals for client " + client.resourceClass.toString());

        client.onInteractiveMoveResizeStarted.connect(onInteractiveMoveResizeStarted);
        client.onInteractiveMoveResizeStepped.connect(onInteractiveMoveResizeStepped);
        client.onInteractiveMoveResizeFinished.connect(onInteractiveMoveResizeFinished);
        client.onFullScreenChanged.connect(onFullScreenChanged);

        function onInteractiveMoveResizeStarted() {
            Utils.log("Interactive move/resize started for client " + client.resourceClass.toString());
            if (client.resizeable && Utils.checkFilter(client)) {
                if (client.move && Utils.checkFilter(client)) {
                    cachedClientArea = clientArea;

                    if (config.fadeWindowsWhileMoving) {
                        for (let i = 0; i < Workspace.stackingOrder.length; i++) {
                            const client = Workspace.stackingOrder[i];
                            client.previousOpacity = client.opacity;
                            if (client.move ||!client.normalWindow) continue;
                            client.opacity = 0.5;
                        }
                    }

                    if (config.rememberWindowGeometries && client.zone != -1) {
                        if (client.oldGeometry) {
                            const geometry = client.oldGeometry;
                            const zone = config.layouts[client.layout].zones[client.zone];
                            const zoneCenterX = (zone.x + zone.width / 2) / 100 * cachedClientArea.width + cachedClientArea.x;
                            const zoneX = ((zone.x / 100) * cachedClientArea.width + cachedClientArea.x);
                            const newGeometry = Qt.rect(Math.round(Workspace.cursorPos.x - geometry.width / 2), Math.round(client.frameGeometry.y), Math.round(geometry.width), Math.round(geometry.height));
                            client.frameGeometry = newGeometry;
                        }
                    }

                    moving = true;
                    moved = false;
                    resizing = false;
                    Utils.log("Move start " + client.resourceClass.toString());
                    mainDialog.show();
                }
                if (client.resize) {
                    moving = false;
                    moved = false;
                    resizing = true;
                }
            }
        }

        function onInteractiveMoveResizeStepped() {
            if (client.resizeable) {
                if (moving && Utils.checkFilter(client)) {
                    moved = true;
                }
            }
        }

        function onInteractiveMoveResizeFinished() {
            Utils.log("Interactive move/resize finished for client " + client.resourceClass.toString());

            if (config.fadeWindowsWhileMoving) {
                for (let i = 0; i < Workspace.stackingOrder.length; i++) {
                    const client = Workspace.stackingOrder[i];
                    client.opacity = client.previousOpacity || 1;
                }
            }

            if (moving) {
                Utils.log("Move end " + client.resourceClass.toString());
                if (moved) {
                    if (root.shown) {
                        moveClientToZone(client, root.highlightedZone);
                    } else {
                        saveClientProperties(client, -1);
                    }
                }
                mainDialog.hide();
            }  else if (resizing) {
                Utils.matchZone(client, currentLayout, clientArea);
                Utils.log("Resizing end: Matched client " + client.resourceClass.toString() + " to layout.zone " + client.layout + " " + client.zone );
                saveClientProperties(client, client.zone);
            }
            moving = false;
            moved = false;
            resizing = false;
        }

        // fix from https://github.com/gerritdevriese/kzones/pull/25
        function onFullScreenChanged() {
            Utils.log("Client fullscreen: " + client.resourceClass.toString() + " (fullscreen " + client.fullScreen + ")");
            if(client.fullScreen == true) {
                Utils.log("onFullscreenChanged: Client zone: " + client.zone + " layout: " + client.layout);
                if (client.zone != -1 && client.layout != -1) {
                    //check if fullscreen is enabled for layout or for zone
                    const layout = config.layouts[client.layout];
                    const zone = layout.zones[client.zone];
                    Utils.log("Layout.fullscreen: " + layout.fullscreen + " Zone.fullscreen: " + zone.fullscreen);
                    if(layout.fullscreen == true || zone.fullscreen == true) {
                        const currentZones = repeaterLayout.itemAt(client.layout)
                        const zoneItem = currentZones.repeater.itemAt(client.zone);
                        const itemGlobal = zoneItem.mapToGlobal(Qt.point(0, 0));
                        const newGeometry = Qt.rect(Math.round(itemGlobal.x), Math.round(itemGlobal.y), Math.round(zoneItem.width), Math.round(zoneItem.height));
                        Utils.log("Fullscreen client " + client.resourceClass.toString() + " to zone " + client.zone + " with geometry " + JSON.stringify(newGeometry));
                        client.setMaximize(false, false);
                        client.frameGeometry = newGeometry;
                    }
                }
            }
            mainDialog.hide();
        }

    }
}