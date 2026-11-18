import Foundation
import Testing
@testable import SwitchyardCore

@Test func firefoxUsesTheInstallDefaultAndReadsItsContainers() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "switchyard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let zen = support.appending(path: "zen")
    try FileManager.default.createDirectory(at: zen.appending(path: "Profiles/b.Work"), withIntermediateDirectories: true)
    try """
    [Profile1]
    Name=Old
    IsRelative=1
    Path=Profiles/a.Old
    Default=1

    [Profile0]
    Name=Work
    IsRelative=1
    Path=Profiles/b.Work

    [Install6ED35B3CA1B5D3AF]
    Default=Profiles/b.Work
    """.write(to: zen.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
    try """
    {"identities":[
      {"userContextId":1,"l10nId":"user-context-personal","public":true},
      {"userContextId":7,"name":"Work","public":true},
      {"userContextId":9,"name":"thumbnail","public":false}
    ]}
    """.write(to: zen.appending(path: "Profiles/b.Work/containers.json"), atomically: true, encoding: .utf8)

    try """
    {"addons":[{"id":"{f069aec0-43c5-4bbf-b6b4-df95c4326b98}","active":true}]}
    """.write(to: zen.appending(path: "Profiles/b.Work/extensions.json"), atomically: true, encoding: .utf8)

    let found = ProfileDiscovery.profiles(for: .firefox(dataDir: "zen"), in: support)
    #expect(found.profiles.map(\.name) == ["Old", "Work"])
    #expect(found.containers == ["Personal", "Work"])
    #expect(found.hasContainerExtension)
    // The cache must notice a new container or extension, not only a new profile.
    #expect(ProfileDiscovery.sourceFiles(for: .firefox(dataDir: "zen"), in: support).map(\.lastPathComponent)
        == ["profiles.ini", "containers.json", "extensions.json"])
}

@Test func ardiaAndChromiumProfilesMapNamesToIDs() {
    let session = Data("""
    {"profiles":{"p-w":{"id":"p-w","name":"Work"},"default":{"id":"default","name":"Personal"}}}
    """.utf8)
    #expect(ProfileDiscovery.ardiaProfiles(session: session).map(\.name) == ["Personal", "Work"])

    let localState = Data("""
    {"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 3":{"name":"Business"}}}}
    """.utf8)
    #expect(ProfileDiscovery.chromiumProfiles(localState: localState)
        == [BrowserProfile(id: "Profile 3", name: "Business"), BrowserProfile(id: "Default", name: "Personal")])
}
