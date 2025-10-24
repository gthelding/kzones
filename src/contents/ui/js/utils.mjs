import { Workspace, config, QML, KWin } from "./core.mjs";

export function log(message, level = "info") {
  if (!config.enableDebugLogging) return;
  console.log(`[${level}] KZones: ${message}`);
}

export function osd(text, icon = "preferences-desktop-virtual") {
  if (!config.showOsdMessages) return;
  QML.dbusCall.exec("org.kde.plasmashell", "/org/kde/osdService", "showText", [icon, text]);
}

export function isPointInside(x, y, geometry) {
  return x >= geometry.x && x <= geometry.x + geometry.width && y >= geometry.y && y <= geometry.y + geometry.height;
}

export function isHovering(item) {
  const itemGlobal = item.mapToGlobal(Qt.point(0, 0));
  return isPointInside(Workspace.cursorPos.x, Workspace.cursorPos.y, {
    x: itemGlobal.x,
    y: itemGlobal.y,
    width: item.width * item.scale,
    height: item.height * item.scale,
  });
}

export function checkFilter(client) {
  if (!client) return false;
  if (!client.normalWindow) return false;
  if (client.popupWindow) return false;
  if (client.skipTaskbar) return false;

  const filter = config.filterList.split(/\r?\n/);
  if (config.filterList.length > 0) {
    if (config.filterMode == 0) {
      // include
      return filter.includes(client.resourceClass.toString());
    }
    if (config.filterMode == 1) {
      // exclude
      return !filter.includes(client.resourceClass.toString());
    }
  }
  return true;
}

export function getClientArea() {
  const activeScreen = Workspace.activeScreen;
  return Workspace.clientArea(KWin.FullScreenArea, activeScreen, Workspace.currentDesktop);
}

export function matchZone(client, currentLayout, clientArea) {
  client.zone = -1;

  // get all zones in the current layout
  const zones = config.layouts[currentLayout].zones;

  // loop through zones and compare with the geometries of the client
  for (let i = 0; i < zones.length; i++) {
    const zone = zones[i];
    const zonePadding = config.layouts[currentLayout].padding || 0;
    const zoneX = (zone.x / 100) * (clientArea.width - zonePadding) + zonePadding;
    const zoneY = (zone.y / 100) * (clientArea.height - zonePadding) + zonePadding;
    const zoneWidth = (zone.width / 100) * (clientArea.width - zonePadding) - zonePadding;
    const zoneHeight = (zone.height / 100) * (clientArea.height - zonePadding) - zonePadding;

    if (
      client.frameGeometry.x == zoneX &&
      client.frameGeometry.y == zoneY &&
      client.frameGeometry.width == zoneWidth &&
      client.frameGeometry.height == zoneHeight
    ) {
      // zone found, set it and exit the loop
      client.zone = i;
      client.layout = currentLayout;
      break;
    }
  }
}

export function getWindowsInZone(zone, layout) {
  const windows = [];
  for (let i = 0; i < Workspace.stackingOrder.length; i++) {
    const client = Workspace.stackingOrder[i];
    if (
      client.zone === zone &&
      client.layout === layout &&
      client.desktop === Workspace.currentDesktop &&
      client.activity === Workspace.currentActivity &&
      client.screen === Workspace.activeWindow.screen &&
      checkFilter(client)
    ) {
      windows.push(client);
    }
  }
  return windows;
}

export function findClientSpecularZone(client, currentLayout, clientArea, isVerticalAxis = false) {
  if (!checkFilter(client)) return null;

  const centerPointOfClient = {
    x: client.frameGeometry.x + client.frameGeometry.width / 2,
    y: client.frameGeometry.y + client.frameGeometry.height / 2,
  };

  const zones = config.layouts[currentLayout].zones;
  let currentZoneIndex = null;
  let closestDistance = Infinity;

  for (let i = 0; i < zones.length; i++) {
    const zone = zones[i];
    let zoneCenter = {
      x: ((zone.x + zone.width / 2) / 100) * clientArea.width + clientArea.x,
      y: ((zone.y + zone.height / 2) / 100) * clientArea.height + clientArea.y,
    };
    const distance = Math.sqrt(
      Math.pow(centerPointOfClient.x - zoneCenter.x, 2) + Math.pow(centerPointOfClient.y - zoneCenter.y, 2)
    );
    if (distance < closestDistance) {
      currentZoneIndex = i;
      closestDistance = distance;
    }
  }

  if (currentZoneIndex === null) return null;

  const currentZone = zones[currentZoneIndex];
  const currentZoneCenter = {
    x: currentZone.x + currentZone.width / 2,
    y: currentZone.y + currentZone.height / 2,
  };

  let specularZoneIndex = null;
  let minDistance = Infinity;

  for (let i = 0; i < zones.length; i++) {
    if (i === currentZoneIndex) continue;

    const zone = zones[i];
    const zoneCenter = {
      x: zone.x + zone.width / 2,
      y: zone.y + zone.height / 2,
    };

    let isSpecular = false;
    if (isVerticalAxis) {
      isSpecular =
        Math.abs(zoneCenter.x - currentZoneCenter.x) < 5 &&
        Math.abs(zoneCenter.y - 50 - (50 - currentZoneCenter.y)) < 5;
    } else {
      isSpecular =
        Math.abs(zoneCenter.y - currentZoneCenter.y) < 5 &&
        Math.abs(zoneCenter.x - 50 - (50 - currentZoneCenter.x)) < 5;
    }

    if (isSpecular) {
      const specularPoint = {
        x: !isVerticalAxis ? 100 - currentZoneCenter.x : currentZoneCenter.x,
        y: isVerticalAxis ? 100 - currentZoneCenter.y : currentZoneCenter.y,
      };
      const distance = Math.sqrt(
        Math.pow(zoneCenter.x - specularPoint.x, 2) + Math.pow(zoneCenter.y - specularPoint.y, 2)
      );
      if (distance < minDistance) {
        specularZoneIndex = i;
        minDistance = distance;
      }
    }
  }

  return specularZoneIndex !== null ? specularZoneIndex : currentZoneIndex;
}

export function findClosestZone(client, currentLayout, clientArea) {
  if (!checkFilter(client)) return null;

  const centerPointOfClient = {
    x: client.frameGeometry.x + client.frameGeometry.width / 2,
    y: client.frameGeometry.y + client.frameGeometry.height / 2,
  };

  const zones = config.layouts[currentLayout].zones;
  let closestZone = null;
  let closestDistance = Infinity;

  for (let i = 0; i < zones.length; i++) {
    const zone = zones[i];
    const zoneCenter = {
      x: ((zone.x + zone.width / 2) / 100) * clientArea.width + clientArea.x,
      y: ((zone.y + zone.height / 2) / 100) * clientArea.height + clientArea.y,
    };
    const distance = Math.sqrt(
      Math.pow(centerPointOfClient.x - zoneCenter.x, 2) + Math.pow(centerPointOfClient.y - zoneCenter.y, 2)
    );
    if (distance < closestDistance) {
      closestZone = i;
      closestDistance = distance;
    }
  }

  return closestZone;
}

export function getCurrentLayout(screenLayouts, currentLayout) {
  if (config.trackLayoutPerScreen) {
    const screenLayout = screenLayouts[Workspace.activeScreen.name];
    if (!screenLayout) {
      screenLayouts[Workspace.activeScreen.name] = 0;
    }
    return screenLayouts[Workspace.activeScreen.name];
  } else {
    return currentLayout;
  }
}

export function setCurrentLayout(screenLayouts, layout) {
  if (config.trackLayoutPerScreen) {
    screenLayouts[Workspace.activeScreen.name] = layout;
  }
  return layout;
}
