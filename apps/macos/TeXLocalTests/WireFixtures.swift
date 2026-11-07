nonisolated let wireSaid = [
    #"{"type":"reply","value":{"id":7,"answer":{"type":"ok","value":"main.tex"}}}"#,
    #"{"type":"reply","value":{"id":8,"answer":{"type":"error","value":{"kind":"notFound","message":{"id":"no_such_session","args":{},"text":"No such session"}}}}}"#,
    #"{"type":"event","value":{"session":1,"event":{"type":"liveAlert"}}}"#,
    #"{"type":"event","value":{"session":1,"event":{"type":"section","value":{"type":"lifecycle","value":{"type":"stopped","value":{"unsaved":["main.tex"]}}}}}}"#,
    #"{"type":"library","value":{"type":"projects","value":[]}}"#,
    #"{"type":"library","value":{"type":"tex","value":{"available":true,"latexmkVersion":"4.86","texDir":null,"found":"/Library/TeX/texbin","texpresso":null,"texpressoDir":null}}}"#,
    #"{"type":"log","value":{"level":"fault","text":"thread 'texlocal-session-1' panicked at src/session/build.rs:9:5:\nboom"}}"#,
]
