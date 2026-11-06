import struct, sys, os
d = sys.argv[1]; out = sys.argv[2]
m = [("ic11","icon_16x16@2x.png"),("ic12","icon_32x32@2x.png"),("ic07","icon_128x128.png"),("ic13","icon_128x128@2x.png"),
     ("ic08","icon_256x256.png"),("ic14","icon_256x256@2x.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png")]
body = b""
for t, f in m:
    data = open(os.path.join(d, f), "rb").read()
    body += t.encode() + struct.pack(">I", len(data) + 8) + data
open(out, "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
