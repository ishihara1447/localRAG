# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx>=0.27"]
# ///
"""防衛白書 実運用想定 30問評価（git管理版）。

2026-07-16: scratchpad の hakusho_eval30.py を scripts/ へ移設し、内部監査
(docs/RAG_EVAL_INTERNAL_AUDIT_2026-07-16.md)の指摘を反映して堅牢化した版。
改良点:
  - temperature=0 を常に固定（既定0.7のstochastic単発比較でスコアが数点ぶれる問題の是正）
  - 不明応答(d)判定 UNKNOWN を否定形要求に修正（裸の「含まれて」「記載されて」が
    肯定文にマッチしハルシネーションを「不明=正解」と誤判定する脆弱性の除去）
  - (c)キーワード全含有判定を空白正規化してから行う（PDF由来の字間空白で
    「持ち込ま せず」等が誤NGになる再発を防止）
  - 設問22を差し替え: 旧「自衛官が受け取る厚生年金の受給開始年齢」は、白書に
    「厚生年金」の語は無い(0回)が「年金受給開始年齢である65歳」という記述が実在(2回)し、
    モデルの「65歳」回答は白書に忠実で捏造ではなかった（＝不明期待が不適切）。
    白書と完全に無縁な「雇用保険の失業給付」(雇用保険/失業給付ともに白書0回、grep確認済み)へ差替。

2026-07-26 (S01 / 品質ロードマップ Phase A): これまで `ans,_=ask(...)` と捨てていた
chat APIの `sources`（＝検索側の観測データ）を実行ログJSONに保存するようにした。
**採点ロジックは一切変更していない**（合計スコアは変更前と一致することを確認済み）。
HAKUSHO_OUT を指定したときだけJSONを書き出す。未指定なら従来と完全に同じ挙動。

★2026-07-26 (評価ハーネス修正): **設問ごとに一意な `sessionId` を振るようにした**。
それまで sessionId を一切指定していなかったため、30問すべてが既定セッションに積み上がり、
`openAiHistory` 件数ぶんの直前の質疑がコンテキストに混入していた（しかも履歴の中身は
run ごと・過去の手動テストの有無で変わる）。complex-eval / ambiguous-eval と同じ方式に揃えた。
**これはベースラインの定義変更である**。旧ベースライン「28〜29/30」とは連続しないので、
比較する場合は必ず新旧を併記すること（詳細: docs/EVAL_HARNESS_FIXES_2026-07-26.md）。

環境変数: HAKUSHO_SLUG(必須), TOPN, PROMPT_FILE, CHAT_MODEL, LOCALRAG_BASE_URL,
          HAKUSHO_OUT(実行ログJSON出力先。sources を含む),
          HAKUSHO_RUN(sessionId に埋め込む run 識別子。省略時はランダム)。
注意: n=30・単発は依然ノイズを含む。施策比較は最低2回実行しレンジを併記すること。
"""
import os, re, sys, json, time, uuid, httpx
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
# S02: 正規化は scripts/_eval_common.py に集約（挙動は従来と同一）
from _eval_common import strip_think, squash_ws, is_unknown
BASE=os.environ.get("LOCALRAG_BASE_URL","http://localhost:3001")
SLUG=os.environ.get("HAKUSHO_SLUG","hakusho-eval")
OUT=os.environ.get("HAKUSHO_OUT","")
TIMEOUT=300.0
# 不明応答検出。否定語を伴わない裸の「含まれて」「記載されて」「該当する」は
# 肯定文にもマッチしハルシネーションを見逃すため、否定形を要求する。
# 2026-08-05: 棄権判定を _eval_common.is_unknown へ一本化した。
# 裸の「見つかり」「お答えでき」が肯定形（見つかりました／お答えできます）にも
# 一致し、ハルシネーションを棄権＝正解と数えていた欠陥を直したもの。
# ここで再定義しないこと。
# (cat, question, spec)  spec: str=regex / ("kw",[...])=全キーワード / None=不明期待
CASES=[
 ("a","防衛省・自衛隊に統合作戦司令部が新設されたのはいつですか。", r"2025\s*年\s*3\s*月\s*24\s*日|令和7年3月24日"),
 ("a","統合作戦司令部はどこに設置されましたか。", r"市ヶ谷"),
 ("a","「自由で開かれたインド太平洋（FOIP）」は、いつ、誰が提唱した考え方ですか。", r"(?=.*2016)(?=.*安倍)"),
 ("a","国家安全保障戦略・国家防衛戦略・防衛力整備計画のいわゆる「三文書」が閣議で決定されたのはいつですか。", r"(令和4年|2022\s*年)\s*12\s*月\s*16\s*日"),
 ("a","2024年11月に石破総理大臣が巡閲した記念観閲式は、防衛省・自衛隊の何周年を記念したものですか。", r"70\s*周年"),
 ("a","2024年9月23日に日本領空を侵犯したロシア軍機に対し、航空自衛隊が初めて使用した警告手段は何ですか。", r"フレア"),
 ("a","護衛艦「かが」が初めて艦上着艦に成功した戦闘機の機種は何ですか。", r"F[-\s]?35\s*B"),
 ("a","米国製のトマホークは何年度から取得を開始する予定ですか。", r"2025\s*年度"),
 ("b","2025年度防衛関係費の歳出額（防衛力整備計画対象経費）はいくらですか。", r"8\s*兆\s*4,?748\s*億|84,?748\s*億"),
 ("b","防衛力整備計画（2023〜2027年度）で、新たに必要となる事業にかかる契約額（物件費）はいくら程度ですか。", r"43\s*兆\s*5,?000\s*億|43\.5\s*兆"),
 ("b","中国が公表している2025年度の国防予算は、わが国の防衛関係費の約何倍に達していますか。", r"約?\s*4\.4\s*倍"),
 ("b","SIPRIによると、日本のGDPに占める防衛関係費の割合は何％となっていますか。", r"1\.4\s*[%％]"),
 ("b","営内隊舎の居室の個室化について、陸上自衛隊と、海上・航空自衛隊の整備完了目標年度はそれぞれいつですか。", r"(?=.*2025\s*年度)(?=.*2028\s*年度)"),
 ("b","現在運用中のXバンド防衛通信衛星「きらめき2号」は、何年度に運用を終了する予定ですか。", r"2030\s*年度"),
 ("c","「専守防衛」とはどのような姿勢のことですか。", ("kw",["武力攻撃を受けた","必要最小限","受動的"])),
 ("c","「非核三原則」とは何ですか。", ("kw",["持たず","作らず","持ち込ませず"])),
 ("c","白書のいう「反撃能力」とはどのような能力ですか。", ("kw",["三要件","相手の領域","スタンド","必要最小限"])),
 ("c","「文民統制（シビリアン・コントロール）」とはどのような考え方ですか。", ("kw",["政治の優先","民主","統制"])),
 ("c","「衛星コンステレーション」とはどのようなシステムですか。", ("kw",["小型","衛星","一体的","情報収集"])),
 ("c","憲法第9条第2項でいう「交戦権」とは何を指しますか。", ("kw",["交戦国","国際法上","権利"])),
 ("d","防衛力強化のための財源確保として、消費税率は何％引き上げられることになっていますか。", None),
 ("d","雇用保険の失業給付（基本手当）の日額の上限はいくらですか。", None),  # 白書に無い(雇用保険/失業給付=0回)。差替経緯はモジュールdocstring参照
 ("d","2025年度の全国加重平均の最低賃金はいくらですか。", None),
 ("d","国民年金の保険料は月額いくらですか。", None),
 ("d","防衛費増額に伴い、診療報酬は何％改定されましたか。", None),
 ("e","陸・海・空自の部隊を一元的に指揮する新しい司令部が「発足」したのはいつですか。", r"2025\s*年\s*3\s*月\s*24\s*日|令和7年3月24日"),
 ("e","航空管制の仕事をする自衛官に新しく設けられた手当は、1尉の場合、毎月いくら支給されますか。", r"32,?000|3\s*万\s*2,?000|3万2千"),
 ("e","予備自衛官手当などの引き上げにより、1任期（3年）あたりの受取総額は改定後いくらになりますか。", r"68\s*万円?"),
 ("e","入隊して営舎や艦艇の中で暮らす隊員に支給される給付金は、採用後6年間で合計いくら受け取れますか。", r"120\s*万円?|1,?200,?000"),
 ("e","陸・海・空自の主要部隊を平常時からひとまとめに指揮するトップの役職名は何ですか。", r"統合作戦司令官"),
]
def newkey(c): return c.post(f"{BASE}/api/system/generate-api-key",json={"name":"e30"}).json()["apiKey"]["secret"]
def ask(c,h,q,session):
    # sessionId を必ず渡す。省略すると全問が既定セッションに積まれ、直前の
    # 質疑（＝他設問の回答や過去の手動テスト）が履歴としてコンテキストに入り、
    # run 間で条件が変わってしまう。設問ごとに独立させる。
    r=c.post(f"{BASE}/api/v1/workspace/{SLUG}/chat",headers=h,
             json={"message":q,"mode":"query","sessionId":session},timeout=TIMEOUT)
    r.raise_for_status(); d=r.json()
    # S01: sources は title だけに潰さず生のまま返す。title は全問 R07zenpen.pdf で
    # 情報量ゼロであり、観測データとして意味があるのは text / pageNumber / score のため。
    return strip_think(d.get("textResponse","") or ""),(d.get("sources",[]) or [])
def grade(ans,spec):
    if spec is None: return is_unknown(ans)
    if isinstance(spec,tuple):
        # PDF由来の字間空白を吸収してからキーワード全含有を判定
        a=squash_ws(ans)
        return all(squash_ws(k) in a for k in spec[1])
    return bool(re.search(spec,ans))
def main():
    with httpx.Client() as c:
        h={"Authorization":f"Bearer {newkey(c)}"}
        # 決定性の担保: 評価は必ずtemperature=0で行う（内部監査2026-07-16）
        c.post(f"{BASE}/api/v1/workspace/{SLUG}/update",headers=h,json={"openAiTemp":0}); print("(temperature=0)")
        tn=os.environ.get("TOPN")
        if tn: c.post(f"{BASE}/api/v1/workspace/{SLUG}/update",headers=h,json={"topN":int(tn)}); print(f"(topN={tn})")
        cm=os.environ.get("CHAT_MODEL")
        if cm: c.post(f"{BASE}/api/v1/workspace/{SLUG}/update",headers=h,json={"chatProvider":"ollama","chatModel":cm}); print(f"(chatModel={cm})")
        pf=os.environ.get("PROMPT_FILE")
        if pf: c.post(f"{BASE}/api/v1/workspace/{SLUG}/update",headers=h,json={"openAiPrompt":open(pf,encoding='utf-8').read()}); print("(prompt overridden)")
        run=os.environ.get("HAKUSHO_RUN") or uuid.uuid4().hex[:8]
        print(f"(sessionId per question, run={run})")
        cats={}; log=[]
        for i,(cat,q,spec) in enumerate(CASES,1):
            t0=time.time()
            sid=f"hakusho-{run}-{i:02d}"
            ans,srcs=ask(c,h,q,sid)
            ok=grade(ans,spec)
            cats.setdefault(cat,[0,0]); cats[cat][1]+=1; cats[cat][0]+=ok
            log.append({"no":i,"cat":cat,"question":q,"ok":bool(ok),
                        "answer":ans,"sec":round(time.time()-t0,1),
                        "session":sid,"sources":srcs})
            print(f"[{'OK' if ok else 'NG'}] ({cat}) {q[:34]}…")
            if not ok: print(f"      → {ans[:130]}")
        print("\n=== カテゴリ別 ===")
        L={"a":"直接事実","b":"数値判別","c":"定義説明","d":"白書外(不明)","e":"言い換え"}
        to=tn2=0
        for cat in "abcde":
            if cat in cats: o,n=cats[cat]; to+=o; tn2+=n; print(f"  {cat}) {L[cat]}: {o}/{n}")
        print(f"=== 合計: {to}/{tn2} ===")
        if OUT:
            with open(OUT,"w",encoding="utf-8") as f:
                json.dump({"slug":SLUG,"run":run,"topN":os.environ.get("TOPN"),
                           "chat_model":os.environ.get("CHAT_MODEL"),
                           "total":[to,tn2],
                           "by_cat":{k:v for k,v in cats.items()},
                           "cases":log},f,ensure_ascii=False,indent=1)
            print(f"(実行ログJSON → {OUT})")
main()
