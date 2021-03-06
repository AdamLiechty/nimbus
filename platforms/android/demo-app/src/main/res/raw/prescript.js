// Copyright (c) 2019, salesforce.com, inc.
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
// For full license text, see the LICENSE file in the repo root or https://opensource.org/licenses/BSD-3-Clause

function systemAlertHandler(color) {
    if (color === "red") {
        console.log("high alert");
    }
}

function removeSystemAlertHandler() {
    Nimbus.unsubscribeMessage("systemAlert", systemAlertHandler);
}

Nimbus.subscribeMessage("systemAlert", systemAlertHandler);
Nimbus.subscribeMessage("removeSystemAlertHandler", removeSystemAlertHandler);
