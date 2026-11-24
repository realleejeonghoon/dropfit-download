// 업데이트 점검용 시험 EdDSA(Ed25519) 키: 키체인을 쓰지 않는다 (update_local_prep.sh)
//   edsign key 파일        시험 개인 키를 파일에 만들고 공개 키(base64)를 출력
//   edsign sign 파일 대상   대상 파일의 서명(base64)을 출력 (Sparkle sparkle:edSignature와 같은 형식)
// Sparkle의 generate_keys·sign_update는 키체인을 거쳐, 깨끗한 Mac에서 허용 창을 기다리며 멈췄다(11/24 macOS 26, 12분 시간 초과)
import CryptoKit
import Foundation

let a = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
switch a.count > 2 ? a[1] : "" {
case "key":
    let k = Curve25519.Signing.PrivateKey()
    do { try k.rawRepresentation.base64EncodedString().write(toFile: a[2], atomically: true, encoding: .utf8) } catch { fail("키 파일을 쓰지 못함") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign" where a.count > 3:
    guard let s = try? String(contentsOfFile: a[2], encoding: .utf8), let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("키 파일을 읽지 못함") }
    guard let d = FileManager.default.contents(atPath: a[3]), let sig = try? k.signature(for: d) else { fail("대상 파일을 읽지 못함") }
    print(sig.base64EncodedString())
default:
    fail("사용법: edsign key 파일 | edsign sign 키파일 대상")
}
