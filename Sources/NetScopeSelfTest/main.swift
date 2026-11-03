import Foundation

// Tests du moteur NetScopeCore. Usage : swift build && ./.build/debug/NetScopeSelfTest
// Code de sortie : 0 si tout passe, 1 sinon.

setvbuf(stdout, nil, _IOLBF, 0)

let suite = TestSuite()
registerAddressingTests(suite)
registerHardwareTests(suite)
registerModelTests(suite)
registerInventoryTests(suite)

let failures = await suite.run()
exit(failures == 0 ? 0 : 1)
