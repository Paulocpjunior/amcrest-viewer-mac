import XCTest
@testable import AmcrestCore

final class RecordingsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let cam = Camera(name: "T", host: "192.168.1.10", channel: 1)

    func date(_ s: String) -> Date {
        DahuaResponse.cameraDateFormatter(timeZone: utc).date(from: s)!
    }

    func query(_ url: URL?) -> [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testFindObject() {
        XCTAssertEqual(DahuaResponse.findObject("result=08137\r\n"), "08137")
        XCTAssertNil(DahuaResponse.findObject("Error\r\nBad Request!"))
    }

    func testLeArquivosDoFindNextFile() {
        let text = """
        found=2\r
        items[0].Channel=1\r
        items[0].StartTime=2024-01-05 09:30:37\r
        items[0].EndTime=2024-01-05 09:40:37\r
        items[0].Type=dav\r
        items[0].Events[0]=VideoMotion\r
        items[0].Events[1]=AlarmLocal\r
        items[0].FilePath=/mnt/sd/2024-01-05/001/dav/09/09.30.37-09.40.37[M][0@0][0].dav\r
        items[0].Length=1048576\r
        items[0].Flags[0]=Event\r
        items[1].Channel=1\r
        items[1].StartTime=2024-01-05 10:00:00\r
        items[1].EndTime=2024-01-05 11:00:00\r
        items[1].Type=dav\r
        items[1].FilePath=/mnt/sd/2024-01-05/001/dav/10/10.00.00-11.00.00[R][0@0][0].dav\r
        items[1].Flags[0]=Timing\r
        """
        let (found, files) = DahuaResponse.recordings(text, timeZone: utc)
        XCTAssertEqual(found, 2)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].events, ["VideoMotion", "AlarmLocal"])
        XCTAssertEqual(files[0].length, 1_048_576)
        XCTAssertEqual(files[0].duration, 600)
        XCTAssertEqual(files[0].start, date("2024-01-05 09:30:37"))
        XCTAssertEqual(files[1].flags, ["Timing"])
        XCTAssertNil(files[1].length)
    }

    func testNadaEncontrado() {
        let (found, files) = DahuaResponse.recordings("found=0\r\n", timeZone: utc)
        XCTAssertEqual(found, 0)
        XCTAssertTrue(files.isEmpty)
    }

    func testDescartaItemSemCaminho() {
        let text = "found=1\nitems[0].StartTime=2024-01-05 09:30:37\nitems[0].EndTime=2024-01-05 09:40:37\n"
        XCTAssertTrue(DahuaResponse.recordings(text, timeZone: utc).files.isEmpty)
    }

    func testPresets() {
        let text = """
        presets[0].Index=2
        presets[0].Name=Portão
        presets[0].Type=1
        presets[1].Index=1
        presets[1].Name=
        """
        XCTAssertEqual(DahuaResponse.presets(text),
                       [PTZPreset(index: 1, name: "Preset 1"), PTZPreset(index: 2, name: "Portão")])
    }

    func testURLDeBusca() {
        let u = AmcrestEndpoints.mediaFindStart(cam, object: "08137",
                                                from: date("2024-01-05 00:00:00"),
                                                to: date("2024-01-05 23:59:59"), timeZone: utc)
        XCTAssertEqual(u?.path, "/cgi-bin/mediaFileFind.cgi")
        let q = query(u)
        XCTAssertEqual(q["action"], "findFile")
        XCTAssertEqual(q["object"], "08137")
        XCTAssertEqual(q["condition.Channel"], "1")
        XCTAssertEqual(q["condition.StartTime"], "2024-01-05 00:00:00")
        XCTAssertEqual(q["condition.EndTime"], "2024-01-05 23:59:59")
        XCTAssertEqual(q["condition.Types[0]"], "dav")
    }

    func testURLDeDownload() {
        let path = "/mnt/sd/2024-01-05/001/dav/09/09.30.37-09.40.37[M][0@0][0].dav"
        let u = AmcrestEndpoints.loadFile(cam, path: path)!
        let c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.path, "/cgi-bin/RPC_Loadfile" + path)
        XCTAssertEqual(c.host, "192.168.1.10")
    }

    func testRTSPDeReproducao() {
        let u = AmcrestEndpoints.rtspPlayback(cam, from: date("2024-01-05 09:30:37"),
                                              to: date("2024-01-05 09:40:37"), timeZone: utc)
        XCTAssertEqual(u?.absoluteString,
                       "rtsp://192.168.1.10:554/cam/playback?channel=1&starttime=2024_01_05_09_30_37&endtime=2024_01_05_09_40_37")
    }

    func testSetPreset() {
        let q = query(AmcrestEndpoints.setPreset(cam, preset: 3))
        XCTAssertEqual(q["code"], "SetPreset")
        XCTAssertEqual(q["arg2"], "3")
    }
}
