import CoreGraphics
import Foundation

@main
enum LayoutTests {
    typealias Screen = MacBookLayout.Screen
    typealias Change = MacBookLayout.Change

    static func screen(_ id: UInt32, builtin: Bool = false, awake: Bool = true,
                       drawable: Bool = true, main: Bool = false, mirror: UInt32 = 0,
                       x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1512) -> Screen {
        Screen(id: id, builtin: builtin, awake: awake, drawable: drawable, main: main,
               mirrorOf: mirror, hardwarePrimary: mirror == 0 ? id : mirror,
               bounds: CGRect(x: x, y: y, width: width, height: 982))
    }

    static func check(_ name: String, _ screens: [Screen], _ expected: Change?) throws {
        let actual = try MacBookLayout.plan(screens, ownedID: 22)
        precondition(actual == expected, name)
        print("PASS \(name)")
    }

    static func main() throws {
        let mac = screen(11, builtin: true, main: true)
        let ipad = screen(22, x: 1512, width: 1366)
        let ipadMain = screen(22, main: true, width: 1366)
        try check("Mac mini 單接 iPad", [ipadMain], nil)
        try check("Mac mini 加 XREAL", [ipadMain, screen(33, mirror: 22)], nil)
        try check("闔蓋內建面板休眠", [ipadMain, screen(11, builtin: true, awake: false, drawable: false)], nil)
        try check("已延伸", [mac, ipad], nil)
        try check("保留使用者偏好的左側位置", [mac, screen(22, x: -1366, width: 1366)], nil)
        try check("解除 iPad 鏡像", [mac, screen(22, drawable: false, mirror: 11)],
                  Change(unmirror: 22, makeMain: nil, x: 1512, y: 0))
        try check("解除反向鏡像並讓內建面板成為主螢幕",
                  [ipadMain, screen(11, builtin: true, drawable: false, mirror: 22)],
                  Change(unmirror: 11, makeMain: 11, x: 1512, y: 0))
        try check("還原內建主螢幕並以點數排列",
                  [ipadMain, screen(11, builtin: true, x: -1512)],
                  Change(unmirror: nil, makeMain: 11, x: 1512, y: 0))
        try check("保留原本外接主螢幕與其他延伸螢幕",
                  [screen(33, main: true, width: 1920), screen(11, builtin: true, x: 1920, y: -100),
                   screen(22, mirror: 33)], Change(unmirror: 22, makeMain: nil, x: 3432, y: -100))
        try check("保留內建面板原有的外接鏡像群組",
                  [ipadMain, screen(33, x: 1366, width: 1920), screen(11, builtin: true, mirror: 33, x: 1366)],
                  Change(unmirror: nil, makeMain: 33, x: 1920, y: 0))
        do {
            _ = try MacBookLayout.plan([mac, ipad, screen(33, mirror: 22)], ownedID: 22)
            preconditionFailure("不可動到其他螢幕的鏡像來源")
        } catch MacBookLayout.Failure.conflictingMirrors { print("PASS 保護其他活動鏡像") }
        do {
            _ = try MacBookLayout.plan([mac, ipad], ownedID: 999)
            preconditionFailure("不可猜測其他顯示器")
        } catch MacBookLayout.Failure.invalidSnapshot { print("PASS 顯示器已消失") }
    }
}
