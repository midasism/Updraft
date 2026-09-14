# dmgbuild 的配置文件。它本身就是一段 Python，所以下面可以直接写逻辑。
#
# 由 scripts/build-dmg.sh 通过 -D 传入 app 与 background 两个路径，其余布局参数写死在这里。
#
# ⚠️ 这里的窗口尺寸与图标坐标，和 tools/DmgBackground.swift 里画箭头的位置是**同一套坐标**：
#    两边都按窗口左下角为原点、单位为点。改任何一边都必须同步改另一边，否则箭头会和图标错位。
#    （dmgbuild 不会替你校验这件事，只能靠人盯。）

import os

app_path = defines['app']                 # 待打包的 .app
background_path = defines['background']   # 背景图 1x；同目录的 @2x 会被 dmgbuild 自动合成 HiDPI

volume_name = 'Updraft'
format = 'UDZO'                           # gzip 压缩的只读镜像，适合分发

# ---- 根目录内容 ----
# 应用本体 + 一个指向 /Applications 的软链。
# 所谓「拖进去就装好」并没有安装程序在跑，起作用的就是这个软链：
# Finder 把用户拖进软链的文件解析到真实路径，于是文件被移动到了 /Applications。
files = [app_path]
symlinks = {'Applications': '/Applications'}

# ---- 窗口外观 ----
background = background_path
window_rect = ((200, 120), (660, 420))    # 必须与 DmgBackground.swift 的 660x420 一致
default_view = 'icon-view'
show_icon_preview = False

# ---- 图标坐标（y 从窗口底部往上算）----
# 不设 arrange_by，Finder 才会保持我们摆好的位置；一旦设了自动排列，坐标会被忽略。
icon_locations = {
    os.path.basename(app_path): (165, 205),
    'Applications': (495, 205),
}

icon_size = 128
text_size = 13
