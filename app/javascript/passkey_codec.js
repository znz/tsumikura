// WebAuthn の JSON <-> ArrayBuffer の変換 (docs/spec/05-auth.md 5 節)。
//
// 新しいブラウザは PublicKeyCredential.parseCreationOptionsFromJSON /
// parseRequestOptionsFromJSON と credential.toJSON() を持っているのでそれを使い、
// まだ無いブラウザ (2024 年より前の Safari / Firefox など) のために base64url の
// 変換を自前で持つ。webauthn-json のようなライブラリは足さない。
//
// サーバ (webauthn gem) が返す JSON では challenge / user.id /
// excludeCredentials[].id / allowCredentials[].id が base64url の文字列になっている。

export function base64urlToBuffer(value) {
  const padding = "=".repeat((4 - (value.length % 4)) % 4)
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = window.atob(base64)
  const bytes = new Uint8Array(raw.length)

  for (let i = 0; i < raw.length; i++) {
    bytes[i] = raw.charCodeAt(i)
  }

  return bytes.buffer
}

export function bufferToBase64url(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""

  // String.fromCharCode(...bytes) は大きな配列でスタックを溢れさせるので 1 バイトずつ積む
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i])
  }

  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

// ---- 登録 (navigator.credentials.create) ----

export function parseCreationOptions(json) {
  if (typeof window.PublicKeyCredential.parseCreationOptionsFromJSON === "function") {
    return window.PublicKeyCredential.parseCreationOptionsFromJSON(json)
  }

  return {
    ...json,
    challenge: base64urlToBuffer(json.challenge),
    user: { ...json.user, id: base64urlToBuffer(json.user.id) },
    excludeCredentials: (json.excludeCredentials || []).map(descriptorToBuffer)
  }
}

export function creationCredentialToJSON(credential) {
  // toJSON があっても、パスワードマネージャの拡張が差し込んだ実装が例外を投げることがある。
  // そのときは手組みの変換に落とす
  try {
    if (typeof credential.toJSON === "function") return credential.toJSON()
  } catch (error) {
    // 手組みに落ちる
  }

  const response = credential.response

  return {
    type: credential.type,
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    authenticatorAttachment: credential.authenticatorAttachment || null,
    clientExtensionResults: credential.getClientExtensionResults(),
    response: {
      attestationObject: bufferToBase64url(response.attestationObject),
      clientDataJSON: bufferToBase64url(response.clientDataJSON),
      transports: typeof response.getTransports === "function" ? response.getTransports() : []
    }
  }
}

// ---- 認証 (navigator.credentials.get) ----

export function parseRequestOptions(json) {
  if (typeof window.PublicKeyCredential.parseRequestOptionsFromJSON === "function") {
    return window.PublicKeyCredential.parseRequestOptionsFromJSON(json)
  }

  return {
    ...json,
    challenge: base64urlToBuffer(json.challenge),
    allowCredentials: (json.allowCredentials || []).map(descriptorToBuffer)
  }
}

export function requestCredentialToJSON(credential) {
  // creationCredentialToJSON と同じ理由で try/catch する
  try {
    if (typeof credential.toJSON === "function") return credential.toJSON()
  } catch (error) {
    // 手組みに落ちる
  }

  const response = credential.response

  return {
    type: credential.type,
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    authenticatorAttachment: credential.authenticatorAttachment || null,
    clientExtensionResults: credential.getClientExtensionResults(),
    response: {
      clientDataJSON: bufferToBase64url(response.clientDataJSON),
      authenticatorData: bufferToBase64url(response.authenticatorData),
      signature: bufferToBase64url(response.signature),
      userHandle: response.userHandle ? bufferToBase64url(response.userHandle) : null
    }
  }
}

function descriptorToBuffer(descriptor) {
  return { ...descriptor, id: base64urlToBuffer(descriptor.id) }
}
