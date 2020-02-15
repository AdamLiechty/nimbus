//
// Copyright (c) 2019, Salesforce.com, inc.
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
// For full license text, see the LICENSE file in the repo root or https://opensource.org/licenses/BSD-3-Clause
//

import __nimbus from "nimbus-bridge";
import "./nimbus-core-tests";
import "./broadcast-tests";
import "./callback-encodable-tests";
import "./promised-javascript-tests"

window.onload = () => {
  __nimbus;
  mochaTestBridge.ready();
};
