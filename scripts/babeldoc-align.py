"""用 BabelDOC 翻譯，同時記下每頁的段落方框（給 ResearchHub 的對照同步反白用）。

BabelDOC 只有在 --debug 時才把中間資料（含段落方框）寫成 JSON，但 debug 模式的輸出 PDF
會畫滿除錯框，不能給人看。所以這裡不用 --debug，而是在「翻譯完、排版前」這一步掛一個鉤子，
把每一段的方框記下來寫進 RH_ALIGN_OUT，然後照常跑 BabelDOC 的命令列。

BabelDOC 會把每段譯文排進原文那段的同一個方框，所以同一個方框在原文與譯文 PDF 裡
指的是同一段——app 只要知道方框就能對照。

用法：RH_ALIGN_OUT=align.json <babeldoc 的 python> babeldoc-align.py <babeldoc 的參數…>
"""
import json
import os
import re
import sys

import babeldoc.format.pdf.high_level as hl
from babeldoc.main import cli

OUT = os.environ.get("RH_ALIGN_OUT", "align.json")
PAGES = {}
_original = hl.Typesetting.typesetting_document


def _capture(self, document):
    try:
        for page in document.page or []:
            boxes = []
            for para in page.pdf_paragraph or []:
                text = re.sub(r"<[^>]+>|\{v\d+\}", "", para.unicode or "").strip()
                box = para.box
                if box is None:
                    continue
                w, h = box.x2 - box.x, box.y2 - box.y
                # 沒翻到東西的版面標記（plain text／title／fallback_line／isolate_formula…）不算段落
                if len(text) < 2 or w < 20 or h < 4 or re.fullmatch(r"[a-z_ ]+", text):
                    continue
                boxes.append([round(box.x, 1), round(box.y, 1), round(box.x2, 1), round(box.y2, 1)])
            PAGES[page.page_number] = boxes
        count = max(PAGES) + 1 if PAGES else 0
        with open(OUT, "w") as f:
            json.dump({"version": 1, "source": "babeldoc",
                       "pages": [PAGES.get(i, []) for i in range(count)]}, f)
    except Exception as e:  # 記不到對照不影響翻譯本身
        print(f"[researchhub] align capture failed: {e}", file=sys.stderr)
    return _original(self, document)


hl.Typesetting.typesetting_document = _capture

if __name__ == "__main__":
    sys.argv = ["babeldoc"] + sys.argv[1:]
    cli()
