import Foundation
import CoreGraphics
import WorkbenchCore
import RemoteDesktop

/// 模幂参考向量由 Python pow() 生成（128/512/1024/2048 位奇模数）。
private let modPowVectors: [(String, String, String, String)] = [
    ("48d706f789acaf61a776aedbec7087fb9ea2a3108430cd6419ac40c7e17991b77dd4bb8b9ab803281d3c9477a2a8eb21f7c9eca8b4d8f78467a6203622091cd0226d0fb54dc4b883f555abaf4585e82cc8fc68ef7d4156f37b77089966a3593a6a559a87122e963ff87bb30d5dd3290c37577d1d3ac7c54b7e064177f03d2a4755e0aebea766170d0080eca2860f32f3abb665397c361782d68449162b1564a291127d64186d9061fb37d8e11e54fc6c978c3929ff3e38428b578414d1f6c46a4430a7924c568f037c972001dcfd8eb368b2194eb240626358efd9ee8e3e67650838fc10d47e93a84124547d71cf95548b441c360b530bff6d8c7d98cae2c6d692daa1baa379e384d6749e636e71f44375f59de5865e46e7cd2c744c32823cc9b3498e643206c550b17467eabe35b07d3fda3afe670814902933dc69483e02391ec40feca6108c71e8d2e0c3fd12ecd11445ef1c76f700d985fcf17143b97665c5be14d70e6ae0c2ba0a1d675888f6cd280da4820cd7d4eb0e972b8856718ffcd8137081af08eba9ae8559999814d4e6e8ebe416af2e970886323a90b7f4b990bd682422eed4a379221f325e3f68e934f9305dd911adee81f8ceae28fc314d6b4aa62fa7cc4d8cfa3fb5092212327a3de2cb8c37839f776077037cbaa80d57fddc95eae0a2e85ccd1ea8e232d724e7b1a856ec7c79bd1ee120965f2c0ece0b66", "9ec1da474c4e56c1c846e65867600c5a71a9c2687cba87cbce5ae4d2e61ae4d904e4b4aeba2a5d18a9e310b9bd259dc1c75833ded208ddd66f8e7aad941f66348719c8a8f8c09366cb63ab44665eed8c57f7cd26e1522a969f530ef9cc6bc54ca55cb270dcafd5d96714c9ef0012c3a4f60008ca2a79d0b2850565df7e4ef5c14c360fa11edefd76066f4c1977718d195ee169167d49b82dba3982018a9518fa1403c39c7a84e03dd4f7e641b29a977ee7fbd88bdf39a830193902afe0e3921fde4f7d0fbea40545ac340f9df8a615e3c5d442f925939e9b19961e5446c074e6989aa88548c327643c3ecde3a9a11e4e145dfd8830c2af792e854b573872fe8ccd676e7a2bb56a7a089bf37356a0d674153189c9993f36a32b4d28180991cfd1746f5f2e0bd301982c191831bb87e9af920cb39c031f18274288cdbf9693ace0d0f0e23669ec576d41f4f43af56f2367e0a2250095793e5037748916131cdd1096679a477dc9a13025d42965ed1bbb88d485484665aab74dc7db7d4dabac91d2ebce3390a85e760f124833c42f17ecbe65ad5e87ae815177c9dcaf8ddeb4524f7a3e60f06d7ee93bbf4d39156414da62e7c17bc16ad6716519d149c09e9abcb5e57f1a176acd74b31cc31d9c1116387b4d0796a3b810ec48d7e977ee45555f76ab5a33521af7c9a53e8fa3a3b93a44d07e195e6bc265fe47039050b43d219b21", "ac2b2341cf2c2559995e6fd87134445e98f1fff479c2f474085aff5b0a86de7cb6df8143c895100ec70877cd523c02f0b06cfb5b528bae1dfb1728d1998ab97ea952a0d44254886ae63218f148a265b121c7b269f2b806cfe774a4accb499ca604dcd25f49f9ee40424b28580c86c3a8d64c2fa1798033376bc560af3476853d8c58ff43de259e63f6bc982dbb4d74f251e0257f70801fc6a4b9476a4b1e330b65216c2d2d68780bfeea36292e2903fc83126df800098bd561cc56e5e30137a8a5cc6e184d4ba3b7f768542019f6dc81dd84cd5e9d971921c7fc9234d001b1878073f774bdee30df731d00d9f4cabee1dd016c6baacf3e1c4efac05e644527527a3387e4c5699007e559129860e53db79d260ea5b325122c16a263415e9d95b213157d1aad72288098929d21a639ad61e519b8a7d61629346586f074da038093f4df5a1aa8237bf228d5f5b967040f890be8dbb303fef1d3622ca7c5e5970d414f0dde8716cac8d36824ab4979a0e5e4604ea185028bf273112c0f0aeac9e89dda506b777c857d08ab4ea667a6b6a8424b8fd38db973b19246a5172d49abd8e3c99baae20c76db5c4516f839da1c3f093eb11c06ebbaa510d7bd4005577297999a84137f17609f73208e0f16da750f21339749816ba28c745054786297d63014a8a0abf7c0008b72efb2acb9f93aaa75e268610ecffd319f142fe6e0aa902231", "19b56833ea2deb4fef3a50f4156faee9c034532a3d48c9471b94eca1fcc2228513376697ac0692b6b5dff5452b90d07d845cf5ee774e9a08a3e50e01bf27136a1f478c99923508054964dbe8f2055f794e59db0f38afa97ca3db7d913237be65d802c7cda06d921c0ed49170116d95dd51196d6590cbbf7039d0e83417364dd0b1919f5ccded9fa542d829cfc7d906553e86cdb8e1d01f8c410b722bda8c20aaffdef64a2de9aaa4c57c3c850f63e57643b637c6072790366fefea2c72ef861b9e590110cf54264bd177ca3a6c136d0ba68d35ba76fe24df717af8a6e3c5e50537d79e9b70c0fe13ac5dab542a7538eb5210debc31b318cbe093397309711dd75019975c360fc6d7856074d03051dc71c38b643f25ff78c0792d4d6fa6680a487c084db1ad32c96c6a51c4c5c17a6f64a073f6d1a6212080e59c3a62cda2fc561bad1cc5926b07975aacc0c00fd89ab828d62963b35e966e64b314d5f959f8016345274dfc3ad5f38a773c4db27864ba4089de766d54fc670b6c40bdad5303ce14eef80c88a6f33e26c48818a0fef23064051a2303466d008f78cdc6f2cb303d11f1c337d18115fdb86d91510bc4cb23ee22212397d2def632b1b737d69efc33a7740b752147d37d87b8dcf51896332e0cf751d43302fd91d0f5110420fb1f04d37c48e1eb0fb2261a3e302a934920fb53e775ba396df700278c59ce59d4612f"),
    ("48d706f789acaf61a776aedbec7087fb9ea2a3108430cd6419ac40c7e17991b77dd4bb8b9ab803281d3c9477a2a8eb21f7c9eca8b4d8f78467a6203622091cd0226d0fb54dc4b883f555abaf4585e82cc8fc68ef7d4156f37b77089966a3593a6a559a87122e963ff87bb30d5dd3290c37577d1d3ac7c54b7e064177f03d2a4755e0aebea766170d0080eca2860f32f3abb665397c361782d68449162b1564a291127d64186d9061fb37d8e11e54fc6c978c3929ff3e38428b578414d1f6c46a4430a7924c568f037c972001dcfd8eb368b2194eb240626358efd9ee8e3e67650838fc10d47e93a84124547d71cf95548b441c360b530bff6d8c7d98cae2c6d692daa1baa379e384d6749e636e71f44375f59de5865e46e7cd2c744c32823cc9b3498e643206c550b17467eabe35b07d3fda3afe670814902933dc69483e02391ec40feca6108c71e8d2e0c3fd12ecd11445ef1c76f700d985fcf17143b97665c5be14d70e6ae0c2ba0a1d675888f6cd280da4820cd7d4eb0e972b8856718ffcd8137081af08eba9ae8559999814d4e6e8ebe416af2e970886323a90b7f4b990bd682422eed4a379221f325e3f68e934f9305dd911adee81f8ceae28fc314d6b4aa62fa7cc4d8cfa3fb5092212327a3de2cb8c37839f776077037cbaa80d57fddc95eae0a2e85ccd1ea8e232d724e7b1a856ec7c79bd1ee120965f2c0ece0b66", "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c3e0116289bec6faf2d618fc15a9b5b4a0cde23c9c390071ea15675e8334f7b9", "ac2b2341cf2c2559995e6fd87134445e98f1fff479c2f474085aff5b0a86de7cb6df8143c895100ec70877cd523c02f0b06cfb5b528bae1dfb1728d1998ab97ea952a0d44254886ae63218f148a265b121c7b269f2b806cfe774a4accb499ca604dcd25f49f9ee40424b28580c86c3a8d64c2fa1798033376bc560af3476853d8c58ff43de259e63f6bc982dbb4d74f251e0257f70801fc6a4b9476a4b1e330b65216c2d2d68780bfeea36292e2903fc83126df800098bd561cc56e5e30137a8a5cc6e184d4ba3b7f768542019f6dc81dd84cd5e9d971921c7fc9234d001b1878073f774bdee30df731d00d9f4cabee1dd016c6baacf3e1c4efac05e644527527a3387e4c5699007e559129860e53db79d260ea5b325122c16a263415e9d95b213157d1aad72288098929d21a639ad61e519b8a7d61629346586f074da038093f4df5a1aa8237bf228d5f5b967040f890be8dbb303fef1d3622ca7c5e5970d414f0dde8716cac8d36824ab4979a0e5e4604ea185028bf273112c0f0aeac9e89dda506b777c857d08ab4ea667a6b6a8424b8fd38db973b19246a5172d49abd8e3c99baae20c76db5c4516f839da1c3f093eb11c06ebbaa510d7bd4005577297999a84137f17609f73208e0f16da750f21339749816ba28c745054786297d63014a8a0abf7c0008b72efb2acb9f93aaa75e268610ecffd319f142fe6e0aa902231", "3e35920064b5d77d918debf9e35dc7a11cc775fba16eb9057509f8e42e665841afa883dd39dcd28fb3110fb833e2f28057dd6dcd54f91364f503a48ad90439ee7893a5cd959c080b66d678e4f0763a5482d6c2e02c0f38600cb3e9632452331ec2ab317ad851bc869b2553c1123790189952fa6e8e433fa652795d0a509d53d78870a63f1604aa576efbcdcd2182ea1a2a6cdb7fe2ad699c813b4754a4b98e6478edbbdf66fb43d9cded335c196d9ea5d0397831b1fa5397c01d386db203851faa28067cced5c20d5e2efdc7d418d82f6477e3621ffef57f6745e2c9edbad08b856afb5f6d220c3bf54451ddca767bef1ac9f04a8cf8215e8db2c6be006b0235da6466ac1fe86c56a9dcb5a8e22185c6bf9c59f6bffe7c4cd365a35771f2ff870d0af2c41bdff6d2e653b7f42d7f14720c912342adfaf5dcc8b7b9917a4463013a2b881d17c412b88efd4e0f283169d80f9c4b906c3724bcc8e5028ed367ac1148e3cb3122ef948b9dbd1ff7c057d448929a96cc220e2bdae7be59efd0a33b0df2fa3e4b33d02bdbf68e5404f717bc6c9a6d8b62efa96177930da2f7dfb97ac4cd95056e2c623a6e56e11b46fe132d4df6fac8667fe6fc964c4485c3dc042537a166ca522c66750e68547100484b23c34554d9fdfdc1df766171cd4fbf57cd9b4b012c6b12413b2aefc837b4cfc403e5ba16d48cabb115f1a7bbdae216bd63bd"),
    ("9d8ad616fd35cf2c9eaa3ca931b51313", "875d257a0dfff42822335332d0e67b86", "a9be5d2129810b3824c2771116e58929", "0a815783205dc87501304b9df489564c"),
    ("85d4480937ca57974fbf53f112ebe792079d16b11e0b13bd8740ad3d3e20b552347dfac9e08f377374186a9956ff9f67d6c69c92bde0762d7472b4955224f003", "4329e3e8fc1085b64887ef8a967c1b07321cdf2dc8b697c9d5d212ca211d7f5a7c27e2dc15c33ad40a4d85715d55b69665f050a71d0239753a0a94c07b90e448", "d0039fe72ddf3a028045c635a4c724f65330a25f30748f6fc2a5b56c73ea70b92da62b051d4bef6f82212f82b3f011eaae4d6fdfbd5b4fe0879af86c41012b99", "c799682519fac3513b208657f1674e62f7cdab2bf926605a5b35aee960ca1089df7f35c5e8a63f9c5af7b78af0e63af0f7707d985130fd8232f9d67daf4010b4"),
    ("b521868aa1a2ede43969c707e0c729ef9725e629e08f412fc845cff8400f2acd5af066a2f8e2fb320d7a0fbb6d335a2283513e1feea68eb82d3d6e433739625e0e90b559d2eea4e00ebf2bf9e2b2a50d54724692a75005f42d38dcda20248de9a5b69138ef1890eb59a456109aa7507b1a9a4759863f52a4b073b2361bec84c2", "f8e144e2af45047f648741cbd356fa024cf9825297d154c489248511b9590aeabef1c5e41f38f3d6e49609ec1860dfc2dae2d38b89666d16a614e0b2ac4d2445d5d84f2a11f3bcf97aad0ce73ee53997cbc8be136a30c0f75a22960a944f01857e83d51eb6c102f672710353ea7a7824dc3086c99104ae45527e83d4bc3ae231", "e78389acb44790e51b9eaf058147e570dec2be6d2264e758d1fdc286d625c45c0a275becccb93244bb912ac52a7c31ca7e8d89dbcff3c57897a9d725ee84fc71cde7ab22ef5a22eca5e69bd0f9daa0a4047f7a4a7a853f14c064cdc43b248e8fdce4ccd4c18231e26f6215a835e1af1256d2d4801bd4ae1293cd61db0bdf21e7", "9f41a0179a5b208d3b4259a4f67892004b3ee90e7ec4cfba64358378c7232f3b384f315de9835a31a079f278f660608241b3f77e9852b6eed0ea8670a91d6d43d4c5618752aa1ca26c5a0adfe6c697d840733da917c54b3369b581c0bd31aa894eb4083c10f5de7c9690784797761e67f256169f8869fec435f6fd9eb646be50"),
    ("4daa9c06d5b5308efeba1c5611b16f68cbde7953a6b4819acaa0a0cfa2a676f1b4898533cdbf784666da746be87b3ae70ee71f28cba52a0d63f25cbd6f7b8b09e283ac77ced95dafde7b2ff3d46ea04e723dfbef993c9605f478fa68c007c2e92f24dda178bfee837c63b9a25344ba130f3a68699affb4b0a72f813e11aefe4a9204611a1adec4238f3f493d2f22373529ff6f43506a2dba237bb2fd359d71bc1c9c46fd315abb194d592c8360657805dccdb41845820d2a976b8ff119fae6d920ceaf2447b1c3d820703f516d915a534f02b0f7fd8e20935fb9de361b9e9922345ae5026e0e9b5c7ec5608dd562f9870018e13614f46f8c9fdf2937a0081205", "8382bafe5a09cba0f540e1ca97019bff7cb0ee2c3921aa35f5ef961ea6beb953bffd069bc0a199ee5f3ca4ef2ed513e6e74aca79d0e9d28f6f22b3abb9bd897db308507051632df6920cb35a9ff7614f5938a5f97234406604ab9c1ca0ade57984f827cc1bf1e703d650b51871b0c7ad6ffba7513d9718f915d22efbfdd65e0016d60d5c12bb7edd5573b0f2903e24735955ab465b97e89afaf2ad3224b9284aec1970bfd84e8f414ee1b5c39ac826791da0adb8d28fe2e3aadde7e6e3d542bf2e1deaf4c5c76b44903964137645c06488cb6dba0f7e0145bebc3829044e488e1ecc3383f2af6f91f4564e15fa3e8970bba5ea61f809e2fc0f0d91388a3537a5", "93b02555fe7e848b6e0b18123a8dea147ccfc029ca8cece00bc280499d52bfc35cf326d5c2348e042cea49eef0563ee7715dcd9ef663775c8056ca00322f5bdc68946864007fcacc31193dfbae162a910897373ae3549879730c86286852cc5956f9c648d234605aa27f621a2c3728f5ac044973462a20422bdae4b1ea30f75e3d7a4eb3d932de74589da545883286d759f0de3cc04d97efb0906a70597ec0c2000160bcf90d3d4722599d394663c4ae857c01f8466a621f1e7cbb447e721514f730a03e5500472cc090ffa1f4b4db718e09a5ffd19b79929f2a8fbf482f402a91b8e39389fddc345e116e715cd240e1fc7a4eae529bda1ff15c191e0ed9a25b", "651bfc6f6c8c89b39c986bf25f647d8b0aa5fad9c5cdb1ff0996878fc1a65bf5c2a14e2f87686be3ba2b2ea0155a0ac12b74eb46e5b8ade3e3740220a2605d0630c4990d0bb38c3c28d5042d23648c578ab7760cbd3eaa444bf2e260a3c39dae829d99c5bfa0bb9c612e5f29f9a7b3b92e8802ed4c1c1447f68263e336230905388380a5aaa507bbca5d0aa138e1b402a8f23499369fe428b0ee0ce43c2af7747f4c413e0a452b89e3ecbfa41fba6ee89b6fefa05c6b237b439cfcd3c0980bdd758bdd40e6d83040c9789905c28a62d067ac5fe83547d3a159c81ec41fa7458c3b36b29db1d93c4e36fa5a4eb1cd1852fbe742af9a346d197e02c03f78346c9a"),
]

private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []; var index = hex.startIndex
    while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); result.append(UInt8(hex[index..<next], radix: 16)!); index = next }
    return result
}

func checkRemoteDesktopMath() throws {
    for (base, exponent, modulus, expected) in modPowVectors {
        let started = ProcessInfo.processInfo.systemUptime
        try expect(RFBDiagnostics.modPow(base: bytes(base), exponent: bytes(exponent), modulus: bytes(modulus)) == bytes(expected), "ARD 模幂与 Python 参考一致（\(modulus.count * 4) 位）")
        if modulus.count == 1024 { print(String(format: "PERF · 4096 位模幂（指数非零位约 %d）%.3fs", bytes(exponent).drop(while: { $0 == 0 }).count * 8, ProcessInfo.processInfo.systemUptime - started)) }
    }
    // VNC 口令：同一挑战、同一口令结果确定；口令超过 8 字节只取前 8 字节。
    let challenge = (0..<16).map { UInt8($0 * 7 & 0xFF) }
    try expect(try RFBDiagnostics.vncResponse(challenge: challenge, password: "farport1") == RFBDiagnostics.vncResponse(challenge: challenge, password: "farport1-ignored"), "VNC 口令只取前 8 字节")
    try expect(try RFBDiagnostics.vncResponse(challenge: challenge, password: "farport1") != RFBDiagnostics.vncResponse(challenge: challenge, password: "farport2"), "不同口令响应不同")
    try expect(RFBKeyboard.character("a") == 0x61 && RFBKeyboard.character("中") == 0x0100_4E2D && RFBKeyboard.character("\u{F700}") == nil, "字符 keysym 映射")
    try expect(RFBKeyboard.modifier(keyCode: 55, mapping: .control) == RFBKeyboard.controlLeft && RFBKeyboard.modifier(keyCode: 55, mapping: .native) == RFBKeyboard.superLeft, "⌘ 按远端类型映射")
}

/// 实测 TigerVNC 夹具：:1 无认证（静态图片），:2 VNC 口令（全屏 xterm 记录按键）。
func checkRemoteDesktopLive(arguments: [String]) throws {
    if ProcessInfo.processInfo.environment["RFB_BENCH"] == "1" {
        let key = arguments[3], knownHosts = arguments[4], sshPort = arguments[2]
        for (route, quality, encodings) in [("SSH -W", RFBQuality.balanced, [Int32]?.none), ("SSH -W", .lossless, [16, 1]), ("SSH -W", .lossless, [5, 1])] {
            var process: Process?
            let stream: RFBStream
            var pipes: [Pipe] = []
            if route == "直连" { stream = try RFBStream.connect(host: "127.0.0.1", port: 25903) }
            else {
                let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                child.arguments = ["-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(knownHosts)", "-o", "StrictHostKeyChecking=yes",
                                   "-p", sshPort, "-T", "-o", "ClearAllForwardings=yes", "-W", "127.0.0.1:5903", "tester@127.0.0.1"]
                let input = Pipe(), output = Pipe(); child.standardInput = input; child.standardOutput = output; pipes = [input, output]
                try child.run(); process = child
                stream = RFBStream(readDescriptor: output.fileHandleForReading.fileDescriptor, writeDescriptor: input.fileHandleForWriting.fileDescriptor, ownsDescriptors: false)
            }
            let client = RFBClient(stream: stream, quality: quality)
            client.preferredEncodings = encodings
            let ready = DispatchSemaphore(value: 0)
            client.events.connected = { _ in ready.signal() }
            client.start(); _ = ready.wait(timeout: .now() + 10)
            Thread.sleep(forTimeInterval: 1)
            let frames0 = client.statistics.frames, bytes0 = client.counters.received, decode0 = client.decodeTime, started = ProcessInfo.processInfo.systemUptime
            Thread.sleep(forTimeInterval: 8)
            let elapsed = ProcessInfo.processInfo.systemUptime - started, frames = client.statistics.frames - frames0
            print(String(format: "BENCH · %@ %@ 2560×1440：%.1f fps，%.1f MB/s，每帧接收解码 %.1f ms，编码 %@", route, quality.rawValue, Double(frames) / elapsed,
                         Double(client.counters.received - bytes0) / elapsed / 1_048_576, (client.decodeTime - decode0) / Double(max(1, frames)) * 1000, client.lastEncoding))
            client.stop(); process?.terminate(); _ = pipes
        }
        return
    }
    guard arguments.count >= 5 else { throw WorkbenchError.message("用法：--rfb-check <docker> <容器> <ssh端口> <私钥> <known_hosts>") }
    let docker = arguments[0], container = arguments[1], sshPort = arguments[2], key = arguments[3], knownHosts = arguments[4]
    func shell(_ command: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["exec", "-u", "tester", container, "sh", "-c", command]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw WorkbenchError.message("夹具命令失败：\(command)\n\(output)") }
        return output
    }
    func wait(_ what: String, timeout: TimeInterval = 15, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() { guard Date() < deadline else { throw WorkbenchError.message("等待超时：\(what)") }; Thread.sleep(forTimeInterval: 0.05) }
    }
    final class Session {
        let client: RFBClient
        var connected: RFBServerInfo?
        var closed: Error??
        var clipboard: [String] = []
        var extended = false
        let lock = NSLock()
        init(_ client: RFBClient) { self.client = client }
    }
    func open(_ stream: RFBStream, encodings: [Int32]?, quality: RFBQuality = .lossless, password: String? = nil) -> Session {
        let client = RFBClient(stream: stream, quality: quality)
        client.preferredEncodings = encodings
        let session = Session(client)
        client.events.credentials = { _ in password.map { RFBCredentials(password: $0) } }
        client.events.connected = { info in session.lock.withLock { session.connected = info } }
        client.events.closed = { error in session.lock.withLock { session.closed = .some(error) } }
        client.events.clipboard = { text in session.lock.withLock { session.clipboard.append(text) } }
        client.events.extendedClipboard = { value in session.lock.withLock { session.extended = value } }
        client.start()
        return session
    }
    func frame(_ session: Session, _ label: String) throws -> [UInt32] {
        try wait("\(label) 首帧") {
            if let failure = session.lock.withLock({ session.closed }) { throw WorkbenchError.message("\(label) 连接关闭：\(failure?.localizedDescription ?? "")") }
            return session.client.statistics.frames >= 1
        }
        // 服务端可能把首个完整画面拆成多条更新消息：等到 400ms 内不再有新帧再比对。
        var last = session.client.statistics.frames, quietSince = Date()
        try wait("\(label) 画面稳定") {
            let current = session.client.statistics.frames
            if current != last { last = current; quietSince = Date() }
            return Date().timeIntervalSince(quietSince) > 0.4
        }
        return session.client.framebuffer.snapshot().pixels.map { $0 & 0x00FF_FFFF }
    }
    // 1. Raw 基准与各编码逐像素对照
    let reference = open(try RFBStream.connect(host: "127.0.0.1", port: 25901), encodings: [0])
    let truth = try frame(reference, "Raw")
    try expect(reference.connected?.width == 1280 && reference.connected?.height == 800 && reference.connected?.isMacOS == false, "无认证连接并读到 1280×800 桌面")
    try expect(Set(truth.prefix(5000)).count > 50, "夹具画面包含丰富颜色")
    reference.client.stop()
    for (name, encodings, quality) in [("Hextile", [Int32(5)], RFBQuality.lossless), ("ZRLE", [16], .lossless), ("Tight 无损", [7], .lossless)] {
        let session = open(try RFBStream.connect(host: "127.0.0.1", port: 25901), encodings: encodings, quality: quality)
        let pixels = try frame(session, name)
        session.client.stop()
        let differing = zip(pixels, truth).filter { $0 != $1 }.count
        if differing > 0 {
            var bands = [Int](repeating: 0, count: 8)
            for index in 0..<min(pixels.count, truth.count) where pixels[index] != truth[index] { bands[min(7, index / 1280 / 100)] += 1 }
            let first = zip(pixels, truth).enumerated().first { $0.element.0 != $0.element.1 }
            let got = first.map { String($0.element.0, radix: 16) } ?? "", want = first.map { String($0.element.1, radix: 16) } ?? ""
            print("DEBUG \(name) 各100行差异：\(bands) 首个差异 index=\(first?.offset ?? -1) got=\(got) want=\(want)")
        }
        try expect(pixels.count == truth.count && differing == 0, "\(name) 解码与 Raw 逐像素一致（差异 \(differing) 像素，编码 \(session.client.lastEncoding)）")
    }
    let jpeg = open(try RFBStream.connect(host: "127.0.0.1", port: 25901), encodings: [7], quality: .balanced)
    let lossy = try frame(jpeg, "Tight JPEG"); jpeg.client.stop()
    var total = 0
    for (left, right) in zip(lossy, truth) {
        for shift in [0, 8, 16] { total += abs(Int((left >> UInt32(shift)) & 0xFF) - Int((right >> UInt32(shift)) & 0xFF)) }
    }
    let error = Double(total) / Double(max(1, truth.count * 3))
    try expect(error < 12, String(format: "Tight JPEG 平均误差 %.2f < 12（颜色通道顺序正确）", error))
    print(String(format: "PASS · Raw/Hextile/ZRLE/Tight 无损逐像素一致，Tight JPEG 平均误差 %.2f", error))

    // 2. VNC 口令：错误口令被拒绝，正确口令连接
    let wrong = open(try RFBStream.connect(host: "127.0.0.1", port: 25902), encodings: nil, password: "wrongpwd")
    try wait("错误口令结果") { wrong.lock.withLock { wrong.closed != nil } }
    try expect({ if case .authenticationFailed = (wrong.closed!! as? RFBError) { return true }; return false }(), "错误 VNC 口令返回认证失败")
    let session = open(try RFBStream.connect(host: "127.0.0.1", port: 25902), encodings: nil, password: "farport1")
    _ = try frame(session, "VNC 口令")
    try expect(session.connected?.securityType == 2, "使用 VNC 口令认证")

    // 3. 键盘：向全屏 xterm 中的 cat 输入文本与回车
    for character in "farport 9" { let keysym = RFBKeyboard.character(String(character))!; session.client.key(keysym, down: true); session.client.key(keysym, down: false) }
    session.client.key(0xFFE1, down: true); session.client.key(0x41, down: true); session.client.key(0x41, down: false); session.client.key(0xFFE1, down: false)
    session.client.key(0xFF0D, down: true); session.client.key(0xFF0D, down: false)
    try wait("按键到达 xterm") { (try? shell("cat /tmp/keys.txt")) == "farport 9A\n" }
    // 4. 指针
    session.client.pointer(x: 321, y: 234, buttons: 0)
    try wait("指针位置") { (try? shell("DISPLAY=:2 xdotool getmouselocation"))?.hasPrefix("x:321 y:234") == true }
    print("PASS · VNC 口令认证（错误口令被拒绝）、键盘输入含 Shift 与回车、指针移动到达远端")

    // 5. 剪贴板：扩展剪贴板 UTF-8 双向（含中文）
    try wait("扩展剪贴板能力") { session.lock.withLock { session.extended } }
    let outgoing = "Farport 剪贴板 → 远端 \(Int.random(in: 1000...9999))"
    try expect(session.client.sendClipboard(outgoing), "扩展剪贴板发送中文")
    try wait("远端收到剪贴板") { (try? shell("DISPLAY=:2 xclip -o -selection clipboard")) == outgoing }
    let incoming = "远端 → Farport 剪贴板 \(Int.random(in: 1000...9999))"
    _ = try shell("printf %s '\(incoming)' | DISPLAY=:2 xclip -i -selection clipboard")
    try wait("本端收到剪贴板") { session.lock.withLock { session.clipboard.contains(incoming) } }
    session.client.stop()
    print("PASS · 扩展剪贴板 UTF-8 中文双向同步")

    // 6. 经 SSH -W 承载 RFB（不开本地端口）
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(knownHosts)", "-o", "StrictHostKeyChecking=yes",
                         "-p", sshPort, "-T", "-o", "ClearAllForwardings=yes", "-W", "127.0.0.1:5901", "tester@127.0.0.1"]
    let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
    try process.run()
    let tunneled = open(RFBStream(readDescriptor: output.fileHandleForReading.fileDescriptor, writeDescriptor: input.fileHandleForWriting.fileDescriptor, ownsDescriptors: false), encodings: [16])
    let viaSSH = try frame(tunneled, "SSH -W")
    tunneled.client.stop(); process.terminate()
    try expect(viaSSH == truth, "经 SSH -W 的画面与直连 Raw 一致")
    print("PASS · RFB 经 SSH -W 子进程承载，画面与直连一致")

    // 7. 本机 macOS 屏幕共享（若已开启）：握手应选择 ARD 账号认证并请求用户名和密码；返回空凭据即取消，不发起认证尝试。
    if let mac = try? RFBStream.connect(host: "127.0.0.1", port: 5900, timeout: 2) {
        let client = RFBClient(stream: mac)
        let requested = NSLock(); var kind: RFBCredentialKind?; var closed: Error??
        client.events.credentials = { value in requested.withLock { kind = value }; return nil }
        client.events.closed = { error in requested.withLock { closed = .some(error) } }
        client.start()
        try wait("macOS 握手") { requested.withLock { closed != nil } }
        try expect(requested.withLock { kind } == .usernameAndPassword, "macOS 屏幕共享选择 ARD 账号认证并请求用户名和密码")
        try expect(requested.withLock { (closed!! as? RFBError) == .cancelled }, "未提供凭据时取消而不尝试认证")
        print("PASS · 本机 macOS 屏幕共享握手选择 ARD 认证（未发送任何凭据）")
    }
}
