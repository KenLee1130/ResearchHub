# 蕃茄鐘計時動畫的影片來源

全部來自 Pixabay，授權為 [Pixabay Content License](https://pixabay.com/service/license-summary/)
（免費、可修改、可放進自己的作品；不可單獨轉售或當素材再散布）。
已裁成 4:5、截 15 秒並把結尾淡入開頭做成無縫循環、壓成 576×720 H.264（ffmpeg）。

| 檔名 | 原始頁面 | 作者 |
|---|---|---|
| pomo-scene-study.mp4 | https://pixabay.com/videos/ai-generated-anime-girl-study-379719/ | Turning_Pages |
| pomo-scene-bedread.mp4 | https://pixabay.com/videos/anime-lofi-girl-anime-girl-reading-345955/ | TuneZoro |
| pomo-scene-nightdesk.mp4 | https://pixabay.com/videos/girl-study-anime-cartoon-drawing-276498/ | Earth_to_Infinity |
| pomo-scene-windowview.mp4 | https://pixabay.com/videos/anime-cozy-evening-night-ambience-309388/ | TuneZoro |
| pomo-scene-raincat.mp4 | https://pixabay.com/videos/anime-lofi-cat-cozy-rain-312345/ | TuneZoro |
| pomo-scene-fireplacecat.mp4 | https://pixabay.com/videos/lofi-cat-fireplace-fire-sleeping-246242/ | Earth_to_Infinity |
| pomo-scene-traincat.mp4 | https://pixabay.com/videos/cat-train-retro-chill-relax-anime-301247/ | Earth_to_Infinity |
| pomo-scene-sunsettrain.mp4 | https://pixabay.com/videos/train-ride-girl-sunset-anime-90408/ | ESphotos |
| pomo-scene-lakecamp.mp4 | https://pixabay.com/videos/anime-camping-campfire-tent-lake-369395/ | Hideaki_AnimeTH |
| pomo-scene-kettlecamp.mp4 | https://pixabay.com/videos/ai-created-anime-camping-campfire-367792/ | Hideaki_AnimeTH |

換影片：照同樣的 ffmpeg 參數做一支 `pomo-scene-<名字>.mp4` 放進這個資料夾，
再在 `Views/PomodoroScenes.swift` 的 `PomodoroScene` 加一個 case，並在 `project.pbxproj` 的 ResearchHub（Mac）例外清單加上這個檔名（Mac 不打包直版）。
