import AbacusMCP
import Testing

@Suite("MCP · skeleton")
struct AbacusMCPSkeletonTests {
  @Test("The server has a name")
  func serverName() {
    #expect(AbacusMCP.serverName == "abacus-mcp")
  }
}
