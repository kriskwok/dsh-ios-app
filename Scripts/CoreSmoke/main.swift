import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("core smoke failed: \(message)\n", stderr)
        exit(1)
    }
}

do {
    let remote = try ServerProfile.validated(
        name: " Production ",
        address: "DSH.EXAMPLE.COM/",
        username: " admin "
    )
    require(remote.name == "Production", "name normalization")
    require(remote.baseURL.absoluteString == "https://dsh.example.com", "HTTPS URL normalization")
    require(remote.username == "admin", "username normalization")

    let local = try ServerProfile.validated(
        name: "LAN",
        address: "http://dshbox.local:3080",
        username: ""
    )
    require(local.baseURL.absoluteString == "http://dshbox.local:3080", "local HTTP URL")

    do {
        _ = try ServerProfile.validated(
            name: "Unsafe",
            address: "http://dsh.example.com",
            username: ""
        )
        require(false, "public HTTP must be rejected")
    } catch ServerProfile.ValidationError.insecureRemoteURL {
        // Expected.
    }

    do {
        _ = try ServerProfile.validated(
            name: "Subpath",
            address: "https://dsh.example.com/app",
            username: ""
        )
        require(false, "subpath deployment must be rejected")
    } catch ServerProfile.ValidationError.pathNotSupported {
        // Expected.
    }

    print("core smoke passed")
} catch {
    fputs("core smoke failed: \(error)\n", stderr)
    exit(1)
}
