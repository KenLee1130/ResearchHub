# Mac 蕃茄鐘浮動面板動畫的影片來源（橫版 16:9）

全部來自 Pixabay，授權為 [Pixabay Content License](https://pixabay.com/service/license-summary/)
（免費、可修改、可放進自己的作品；不可單獨轉售或當素材再散布）。
不裁切；截前 16 秒（較短的整支）、把結尾淡入開頭做成無縫循環、壓成 1280×720 30fps H.264
（ffmpeg：`trim → fps=30 → scale=1280:720 → xfade 1 秒`，`-crf 26 -preset slow`）。

這個資料夾只打包進 Mac（ResearchHub target）；iPhone 用 `PomodoroScenes/` 的直版。

| 檔名 | 原始頁面 | 作者（Pixabay 帳號） |
|---|---|---|
| pomo-wide-study.mp4 | https://pixabay.com/videos/ai-generated-anime-girl-study-379719/ | Turning_Pages |
| pomo-wide-bedread.mp4 | https://pixabay.com/videos/anime-lofi-girl-anime-girl-reading-345955/ | TuneZoro |
| pomo-wide-nightdesk.mp4 | https://pixabay.com/videos/girl-study-anime-cartoon-drawing-276498/ | Earth_to_Infinity |
| pomo-wide-windowview.mp4 | https://pixabay.com/videos/anime-cozy-evening-night-ambience-309388/ | TuneZoro |
| pomo-wide-raincat.mp4 | https://pixabay.com/videos/anime-lofi-cat-cozy-rain-312345/ | TuneZoro |
| pomo-wide-fireplacecat.mp4 | https://pixabay.com/videos/lofi-cat-fireplace-fire-sleeping-246242/ | Earth_to_Infinity |
| pomo-wide-traincat.mp4 | https://pixabay.com/videos/cat-train-retro-chill-relax-anime-301247/ | Earth_to_Infinity |
| pomo-wide-sunsettrain.mp4 | https://pixabay.com/videos/train-ride-girl-sunset-anime-90408/ | ESphotos |
| pomo-wide-lakecamp.mp4 | https://pixabay.com/videos/anime-camping-campfire-tent-lake-369395/ | Hideaki_AnimeTH |
| pomo-wide-kettlecamp.mp4 | https://pixabay.com/videos/ai-created-anime-camping-campfire-367792/ | Hideaki_AnimeTH |
| pomo-wide-readcat.mp4 | https://pixabay.com/videos/ai-generated-anime-cozy-rain-297863/ | shayea_kim |
| pomo-wide-umbrella.mp4 | https://pixabay.com/videos/anime-lofi-cozy-rain-rainy-night-311563/ | earth_to_infinity |
| pomo-wide-nighttrain.mp4 | https://pixabay.com/videos/anime-lofi-cozy-night-train-311602/ | earth_to_infinity |
| pomo-wide-desklamp.mp4 | https://pixabay.com/videos/lofi-nature-anime-to-relax-night-319697/ | camilatpb |
| pomo-wide-sunsetwrite.mp4 | https://pixabay.com/videos/man-anime-sunset-writing-lo-fi-330218/ | xbriantcx |
| pomo-wide-raincafe.mp4 | https://pixabay.com/videos/coffee-shop-coffee-restaurant-lofi-331618/ | nguyenthong7997 |
| pomo-wide-lampcat.mp4 | https://pixabay.com/videos/anime-lofi-cat-cute-cat-345856/ | wodokolor |
| pomo-wide-fireread.mp4 | https://pixabay.com/videos/ai-generated-anime-girl-cozy-room-360380/ | shayea_kim |
| pomo-wide-rainlaptop.mp4 | https://pixabay.com/videos/rain-rainy-night-cozy-working-376044/ | vimeo-free-videos |
| pomo-wide-heavyrain.mp4 | https://pixabay.com/videos/heavy-rain-night-cozy-window-376049/ | distillvideos |
| pomo-wide-sunrisecat.mp4 | https://pixabay.com/videos/lofi-chill-nature-cat-sunrise-270507/ | spectrumaudio |
| pomo-wide-headphones.mp4 | https://pixabay.com/videos/lofi-girl-chill-for-chill-study-265816/ | spectrumaudio |
| pomo-wide-lamplaptop.mp4 | https://pixabay.com/videos/ai-generated-anime-girl-laptop-379720/ | shayea_kim |
| pomo-wide-raincabin.mp4 | https://pixabay.com/videos/live-wallpaper-cozy-cabin-rainy-day-270983/ | rostislavuzunov |
| pomo-wide-rainbook.mp4 | https://pixabay.com/videos/ai-generated-book-window-rain-259295/ | u_fdatqgli9y |

換影片：照同樣的 ffmpeg 參數做一支 `pomo-wide-<名字>.mp4` 放進這個資料夾，
在 `Views/PomodoroScenes.swift` 的 `PomodoroScene` 加 case（只有橫版就加進 `wideOnly`），
並在 `project.pbxproj` 的 ResearchHubMobile 例外清單加上這個檔名（不打包進 iPhone）。
