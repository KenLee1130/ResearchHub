"""用 BabelDOC 翻譯，同時記下段落與句子的對照（給 ResearchHub 的對照同步反白用）。

BabelDOC 只有在 --debug 時才把中間資料寫成 JSON，但 debug 模式的輸出 PDF 會畫滿除錯框，
不能給人看。所以這裡不用 --debug，而是掛兩個鉤子：
  1. 翻譯前：記下每一段的原文
  2. 排版前（翻譯完）：記下每一段的譯文與方框
BabelDOC 會把每段譯文排進原文那段的同一個方框，所以同一個方框在原文與譯文 PDF 裡指的是
同一段。段落裡再斷句：句數一樣就一句對一句；對不上的段落另外問 DeepSeek 怎麼切。

輸出（RH_ALIGN_OUT）：
  {"version": 2, "source": "babeldoc", "pageCount": N, "translatedPages": [0 起算的頁碼…],
   "pages": [[[x,y,x2,y2], …], …],                       # 每頁的段落方框（段落等級的退路）
   "paragraphs": [{"page": p, "box": [x,y,x2,y2], "src": [句…], "dst": [句…], "method": "count|llm|whole|ratio"}]}

用法：RH_ALIGN_OUT=align.json [RH_PAGES=12-30] <babeldoc 的 python> babeldoc-align.py <babeldoc 的參數…>
"""
import json
import os
import re
import sys

import babeldoc.format.pdf.high_level as hl
from babeldoc.format.pdf.document_il.midend.il_translator_llm_only import ILTranslatorLLMOnly
from babeldoc.main import cli

OUT = os.environ.get("RH_ALIGN_OUT", "align.json")
ORIGINAL = {}      # id(paragraph) -> (paragraph, page_number, 原文)
PARAGRAPHS = []    # [{"page", "box", "src_text", "dst_text"}]
PAGE_BOXES = {}
PAGE_COUNT = [0]
LAYOUT_LABEL = re.compile(r"[a-z_ ]+")
PLACEHOLDER = re.compile(r"<[^>]+>|\{v\d+\}")


def _clean(text):
    return PLACEHOLDER.sub(" ", text or "").strip()


# ---- 1. 翻譯前：記下原文 -------------------------------------------------------
_original_translate = ILTranslatorLLMOnly.translate


def _before_translate(self, docs):
    try:
        for page in docs.page or []:
            for para in page.pdf_paragraph or []:
                ORIGINAL[id(para)] = (para, page.page_number, para.unicode or "")
    except Exception as e:
        print(f"[researchhub] snapshot failed: {e}", file=sys.stderr)
    return _original_translate(self, docs)


ILTranslatorLLMOnly.translate = _before_translate


# ---- 2. 排版前：記下譯文與方框 -------------------------------------------------
_original_typesetting = hl.Typesetting.typesetting_document


def _capture(self, document):
    try:
        for page in document.page or []:
            PAGE_COUNT[0] = max(PAGE_COUNT[0], page.page_number + 1)
            boxes = []
            for para in page.pdf_paragraph or []:
                box = para.box
                if box is None:
                    continue
                text = _clean(para.unicode)
                w, h = box.x2 - box.x, box.y2 - box.y
                if len(text) < 2 or w < 20 or h < 4 or LAYOUT_LABEL.fullmatch(text):
                    continue
                orig = ORIGINAL.get(id(para))
                # 沒翻到的段落（指定頁數以外、或模型略過的）譯文跟原文一樣，不算
                if orig is None or (orig[2] or "") == (para.unicode or ""):
                    continue
                b = [round(box.x, 1), round(box.y, 1), round(box.x2, 1), round(box.y2, 1)]
                boxes.append(b)
                PARAGRAPHS.append({"page": page.page_number, "box": b,
                                   "src_text": orig[2], "dst_text": para.unicode or ""})
            if boxes:
                PAGE_BOXES[page.page_number] = boxes
    except Exception as e:  # 記不到對照不影響翻譯本身
        print(f"[researchhub] align capture failed: {e}", file=sys.stderr)
    return _original_typesetting(self, document)


hl.Typesetting.typesetting_document = _capture


# ---- 3. 斷句 ----------------------------------------------------------------
ABBREV = r"(?:et al|i\.e|e\.g|cf|vs|Eqs?|Figs?|Refs?|Secs?|Ch|No|Prof|Dr|Tab|resp|approx)"


def split_en(text):
    text = re.sub(r"\s+", " ", _clean(text))
    # 縮寫後的句點先換成記號，斷完再換回來
    text = re.sub(r"\b(" + ABBREV + r")\.", lambda m: m.group(1) + "⁣", text)
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9(\[“\"‘])", text)
    parts = [p.replace("⁣", ".").strip() for p in parts if p.strip()]
    return _merge_short(parts, 12)


def split_zh(text):
    text = re.sub(r"\s+", " ", _clean(text))
    parts = re.split(r"(?<=[。！？])(?![」』）)”’])", text)
    return _merge_short([p.strip() for p in parts if p.strip()], 4)


def _merge_short(parts, minimum):
    out = []
    for p in parts:
        if out and len(p) < minimum:
            out[-1] = out[-1] + " " + p
        else:
            out.append(p)
    if len(out) > 1 and len(out[0]) < minimum:
        out[1] = out[0] + " " + out[1]
        out.pop(0)
    return out


# ---- 4. 句子對不上的段落：問 DeepSeek 怎麼切 ------------------------------------
def _arg(name):
    argv = sys.argv
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
    return None


def align_with_llm(items):
    """items: [(段落, 英文句子們, 中文全文)] → {段落索引: [中文片段…] 或 None}"""
    key, base, model = _arg("--openai-api-key"), _arg("--openai-base-url"), _arg("--openai-model")
    if not (key and base and model) or not items:
        return {}
    try:
        from openai import OpenAI
        client = OpenAI(api_key=key, base_url=base)
    except Exception as e:
        print(f"[researchhub] openai client failed: {e}", file=sys.stderr)
        return {}
    results = {}
    for start in range(0, len(items), 8):   # 一次問 8 段，少一點請求
        batch = items[start:start + 8]
        blocks = []
        for k, (_, en, zh) in enumerate(batch):
            numbered = "\n".join(f"  {i + 1}. {s}" for i, s in enumerate(en))
            blocks.append(f"### 段落 {k}\n英文句子：\n{numbered}\n中文翻譯：\n{zh}")
        prompt = (
            "以下每一段都有英文原文（已斷句編號）與它的中文翻譯。請把中文翻譯切成與英文句子一一對應的片段：\n"
            "- 片段必須逐字取自中文翻譯、依原順序、合起來就是整段中文（不可改字、不可增刪）。\n"
            "- 片段數量必須等於英文句子數量；若某句英文在中文裡被併進鄰句，該句給空字串 \"\"。\n"
            "只輸出 JSON，鍵是段落編號的阿拉伯數字，格式：{\"0\": [\"片段1\", \"片段2\", …], \"1\": […]}\n\n"
            + "\n\n".join(blocks))
        try:
            resp = client.chat.completions.create(
                model=model, temperature=0,
                messages=[{"role": "user", "content": prompt}],
                response_format={"type": "json_object"},
                extra_body={"thinking": {"type": "disabled"}})
            raw = json.loads(resp.choices[0].message.content or "{}")
            # 模型有時把鍵寫成「段落 0」：只取裡面的數字
            data = {}
            for k, v in raw.items():
                m = re.search(r"\d+", str(k))
                if m:
                    data[m.group(0)] = v
        except Exception as e:
            print(f"[researchhub] llm align failed: {e}", file=sys.stderr)
            continue
        for k, (idx, en, zh) in enumerate(batch):
            segs = data.get(str(k))
            norm_zh = re.sub(r"\s+", "", zh)
            if (isinstance(segs, list) and len(segs) == len(en)
                    and all(isinstance(s, str) for s in segs)
                    and all(re.sub(r"\s+", "", s) in norm_zh for s in segs if s)):
                results[idx] = [s.strip() for s in segs]
    return results


def ratio_align(en, zh_sents):
    """最後的退路：照字數比例把中文句子分給英文句子"""
    total_en = sum(len(s) for s in en) or 1
    total_zh = sum(len(s) for s in zh_sents) or 1
    out, acc_en, j = [], 0, 0
    acc_zh = 0
    for s in en:
        acc_en += len(s)
        target = acc_en / total_en * total_zh
        seg = []
        while j < len(zh_sents) and (acc_zh + len(zh_sents[j]) / 2 <= target or not seg):
            seg.append(zh_sents[j])
            acc_zh += len(zh_sents[j])
            j += 1
        out.append("".join(seg))
    if j < len(zh_sents) and out:
        out[-1] += "".join(zh_sents[j:])
    return out


def build_alignment():
    paragraphs, pending = [], []
    for p in PARAGRAPHS:
        en, zh = split_en(p["src_text"]), split_zh(p["dst_text"])
        entry = {"page": p["page"], "box": p["box"], "src": en, "dst": zh}
        if len(en) <= 1 or len(zh) <= 1:
            entry.update(src=[" ".join(en)], dst=[" ".join(zh)], method="whole")
        elif len(en) == len(zh):
            entry["method"] = "count"
        else:
            pending.append((len(paragraphs), en, _clean(p["dst_text"])))
        paragraphs.append(entry)
    llm = align_with_llm(pending)
    for idx, en, _ in pending:
        if idx in llm:
            paragraphs[idx].update(dst=llm[idx], method="llm")
        else:
            paragraphs[idx].update(dst=ratio_align(en, paragraphs[idx]["dst"]), method="ratio")
    return paragraphs


def translated_pages():
    spec = os.environ.get("RH_PAGES", "").strip()
    if not spec:
        return sorted(PAGE_BOXES)
    pages = set()
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            a = int(a) if a else 1
            b = int(b) if b else PAGE_COUNT[0]
            pages.update(range(a - 1, b))
        elif part:
            pages.add(int(part) - 1)
    return sorted(p for p in pages if p < PAGE_COUNT[0] or PAGE_COUNT[0] == 0)


def total_pages():
    """原文總頁數（只翻部分頁時，排版鉤子只看得到翻的那幾頁，不能拿來當總頁數）"""
    path = _arg("--files")
    try:
        import pymupdf
        with pymupdf.open(path) as doc:
            return len(doc)
    except Exception:
        return PAGE_COUNT[0]


def write_alignment():
    count = max(total_pages(), PAGE_COUNT[0])
    PAGE_COUNT[0] = count
    data = {"version": 2, "source": "babeldoc", "pageCount": count,
            "translatedPages": translated_pages(),
            "pages": [PAGE_BOXES.get(i, []) for i in range(count)],
            "paragraphs": build_alignment()}
    with open(OUT, "w") as f:
        json.dump(data, f, ensure_ascii=False)
    methods = {}
    for p in data["paragraphs"]:
        methods[p.get("method")] = methods.get(p.get("method"), 0) + 1
    print(f"[researchhub] align: {len(data['paragraphs'])} paragraphs {methods}", file=sys.stderr)


if __name__ == "__main__":
    sys.argv = ["babeldoc"] + sys.argv[1:]
    try:
        cli()
    finally:
        if PARAGRAPHS:
            write_alignment()
