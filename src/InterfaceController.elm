module InterfaceController (upstate) where

import Lang exposing (..) --For access to what makes up the Vals
import Types
import LangParser2 exposing (parseE, freshen)
import LangUnparser exposing (unparse, precedingWhitespace, addPrecedingWhitespace)
import LangTransform
import ValueBasedTransform
import Sync
import Eval
import Utils
import Keys
import InterfaceModel exposing (..)
import InterfaceView2 as View
import InterfaceStorage exposing (installSaveState, removeDialog)
import LangSvg exposing (toNum, toNumTr, toPoints, addi)
import ExamplesGenerated as Examples
import Config exposing (params)

import VirtualDom

--Core Libraries
import List
import Dict exposing (Dict)
import Set
import String
import Char
import Graphics.Element as GE
import Graphics.Collage as GC
import Regex as Re

--Html Libraries
import Html
import Html.Attributes as Attr
import Html.Events as Events

--Svg Libraries
import Svg
import Svg.Attributes
import Svg.Events
import Svg.Lazy

--Error Checking Libraries
import Debug

--------------------------------------------------------------------------------

debugLog = Config.debugLog Config.debugController

--------------------------------------------------------------------------------

slateToVal : LangSvg.RootedIndexedTree -> Val
slateToVal (rootId, tree) =
  let foo n =
    case n of
      LangSvg.TextNode s -> vList [vBase (String "TEXT"), vBase (String s)]
      LangSvg.SvgNode kind l1 l2 ->
        let vs1 = List.map LangSvg.valOfAttr l1 in
        let vs2 = List.map (foo << flip Utils.justGet tree) l2 in
        vList [vBase (String kind), vList vs1, vList vs2]
          -- NOTE: if relate needs the expression that led to this
          --  SvgNode, need to store it in IndexedTree
  in
  foo (Utils.justGet rootId tree)

upslate : LangSvg.NodeId -> (String, LangSvg.AVal) -> LangSvg.IndexedTree -> LangSvg.IndexedTree
upslate id newattr nodes = case Dict.get id nodes of
    Nothing   -> Debug.crash "upslate"
    Just node -> case node of
        LangSvg.TextNode x -> nodes
        LangSvg.SvgNode shape attrs children ->
            let newnode = LangSvg.SvgNode shape (Utils.update newattr attrs) children
            in Dict.insert id newnode nodes

refreshMode model e =
  case model.mode of
    Live _  -> mkLive_ model.syncOptions model.slideNumber model.movieNumber model.movieTime e
    Print _ -> mkLive_ model.syncOptions model.slideNumber model.movieNumber model.movieTime e
    m       -> m

refreshMode_ model = refreshMode model model.inputExp

refreshHighlights id zone model =
  let codeBoxInfo = model.codeBoxInfo in
  let hi = liveInfoToHighlights id zone model in
  { model | codeBoxInfo = { codeBoxInfo | highlights = hi } }

switchOrient m = case m of
  Vertical -> Horizontal
  Horizontal -> Vertical

-- may want to eventually have a maximum history length
addToHistory currentCode h =
  let (past, _) = h in
  case past of
    [] ->
      (currentCode::past, [])

    last::older ->
      if currentCode == last
      then h
      else (currentCode::past, [])


between1 i (j,k) = i `Utils.between` (j+1, k+1)

cleanExp =
  mapExpViaExp__ <| \e__ -> case e__ of
    EApp _ e0 [e1,_,_] _ -> case e0.val.e__ of
      EVar _ "inferred"  -> e1.val.e__
      _                  -> e__
    EApp _ e0 [_,e1] _   -> case e0.val.e__ of
      EVar _ "flow"      -> e1.val.e__
      _                  -> e__
    EOp _ op [e1,e2] _   ->
      case (op.val, e2.val.e__) of
        (Plus, EConst _ 0 _ _) -> e1.val.e__
        _                      -> e__
    _                    -> e__


-- this is a bit redundant with View.turnOn...
maybeStuff id shape zone m =
  case m.mode of
    Live info ->
      flip Utils.bindMaybe (Dict.get id info.assignments) <| \d ->
      flip Utils.bindMaybe (Dict.get zone d) <| \(yellowLocs,_) ->
        Just (info.initSubst, yellowLocs)
    _ ->
      Nothing

highlightChanges mStuff changes codeBoxInfo =
  case mStuff of
    Nothing -> codeBoxInfo
    Just (initSubstPlus, locs) ->

      let (hi,stringOffsets) =
        -- hi : List Highlight, stringOffsets : List (Pos, Int)
        --   where Pos is start pos of a highlight to offset by Int chars
        let f loc (acc1,acc2) =
          let (locid,_,_) = loc in
          let highlight c = makeHighlight initSubstPlus c loc in
          case (Dict.get locid initSubstPlus, Dict.get locid changes) of
            (Nothing, _)             -> Debug.crash "Controller.highlightChanges"
            (Just n, Nothing)        -> (highlight yellow :: acc1, acc2)
            (Just n, Just Nothing)   -> (highlight red :: acc1, acc2)
            (Just n, Just (Just n')) ->
              if n' == n.val then
                (highlight yellow :: acc1, acc2)
              else
                let (s, s') = (strNum n.val, strNum n') in
                let x = (acePos n.start, String.length s' - String.length s) in
                (highlight green :: acc1, x :: acc2)
        in
        List.foldl f ([],[]) (Set.toList locs)
      in

      let hi' =
        let g (startPos,extraChars) (old,new) =
          let bump pos = { pos | column = pos.column + extraChars } in
          let ret new' = (old, new') in
          ret <|
            if startPos.row    /= old.start.row         then new
            else if startPos.column >  old.start.column then new
            else if startPos.column == old.start.column then { start = new.start, end = bump new.end }
            else if startPos.column <  old.start.column then { start = bump new.start, end = bump new.end }
            else
              Debug.crash "highlightChanges"
        in
        -- hi has <= 4 elements, so not worrying about the redundant processing
        flip List.map hi <| \{color,range} ->
          let (_,range') = List.foldl g (range,range) stringOffsets in
          { color = color, range = range' }
      in

      { codeBoxInfo | highlights = hi' }

addSlateAndCode old (exp, val) =
  let (slate, code) = slateAndCode old (exp, val) in
  (exp, val, slate, code)

slateAndCode old (exp, val) =
  let slate =
    LangSvg.resolveToIndexedTree old.slideNumber old.movieNumber old.movieTime val
  in
  (slate, unparse exp)


--------------------------------------------------------------------------------

clickToCanvasPoint old (mx, my) =
  let (xOrigin, yOrigin) = case old.orient of
    Vertical   -> canvasOriginVertical old
    Horizontal -> canvasOriginHorizontal old
  in
  (mx - xOrigin, my - yOrigin)

-- the computations of the top-left corner of the canvas
-- are based on copying the computations from View
-- TODO: refactor these

canvasOriginVertical old =
  let
    sideGut = params.topSection.h
    wGut    = params.mainSection.vertical.wGut
    wMiddle = params.mainSection.widgets.wBtn
    wCode_  = (fst old.dimensions - sideGut - sideGut - wMiddle - wGut - wGut) // 2
    wCode   = if old.hideCode then 0
              else if old.hideCanvas then (fst old.dimensions - sideGut - sideGut - wMiddle - wGut - wGut)
              else wCode_ + old.midOffsetX
  in
    ( sideGut + wCode + 2*wGut + wMiddle
    , params.topSection.h
    )

canvasOriginHorizontal old =
  -- TODO the y-position in horizontal mode is off by a few pixels
  -- TODO in View, the height of codebox isn't the same as the canvas.
  --   hMid is calculated weirdly in View...
  let
    hTop    = params.topSection.h
    hBot    = params.botSection.h
    hGut    = params.mainSection.horizontal.hGut
    hCode_  = (snd old.dimensions - hTop - hBot - hGut) // 2
    hCode   = hCode_ + old.midOffsetY
    -- TODO consider hideCode and hideCanvas
    wTools  = params.mainSection.widgets.wBtn + 2 * params.mainSection.vertical.wGut
  in
    ( wTools
    , params.topSection.h + hCode + hGut
    )


--------------------------------------------------------------------------------
-- New Shapes

type alias Program = (TopDefs, MainExp)

-- TODO store Idents and "types" in TopDefs. also use for lambda tool.

type alias TopDef  = (WS, Pat, Exp, WS)
type alias TopDefs = List TopDef

type MainExp
  = SvgConcat (List Exp) (List Exp -> Exp)
  | Blobs (List BlobExp) (List BlobExp -> Exp)
  | OtherExp Exp

type BlobExp
  = OtherBlob Exp
  | NiceBlob Exp NiceBlob

type NiceBlob
  = VarBlob Ident                          -- x
  | CallBlob (Ident, List Exp)             -- (f args)
  | WithBoundsBlob (Exp, Ident, List Exp)  -- (with bounds (f args))

varBlob e x            = NiceBlob e (VarBlob x)
callBlob e tuple       = NiceBlob e (CallBlob tuple)
withBoundsBlob e tuple = NiceBlob e (WithBoundsBlob tuple)

splitExp : Exp -> Program
splitExp e =
  case e.val.e__ of
    ELet ws1 Def False p1 e1 e2 ws2 ->
      let (defs, main) = splitExp e2 in
      ((ws1,p1,e1,ws2)::defs, main)
    _ ->
      ([], toMainExp e)

fuseExp : Program -> Exp
fuseExp (defs, mainExp) =
  let recurse defs =
    case defs of
      [] -> fromMainExp mainExp
      (ws1,p1,e1,ws2)::defs' ->
        withDummyPos <| ELet ws1 Def False p1 e1 (recurse defs') ws2
  in
  recurse defs

toMainExp : Exp -> MainExp
toMainExp e =
  maybeSvgConcat e `Utils.plusMaybe` maybeBlobs e `Utils.elseMaybe` OtherExp e

fromMainExp : MainExp -> Exp
fromMainExp me =
  case me of
    SvgConcat shapes f -> f shapes
    Blobs shapes f     -> f shapes
    OtherExp e         -> e

maybeSvgConcat : Exp -> Maybe MainExp
maybeSvgConcat main =
  case main.val.e__ of
    EApp ws1 e1 [eAppConcat] ws2 ->
      case (e1.val.e__, eAppConcat.val.e__) of
        (EVar _ "svg", EApp ws3 eConcat [e2] ws4) ->
          case (eConcat.val.e__, e2.val.e__) of
            (EVar _ "concat", EList ws5 oldList ws6 Nothing ws7) ->
              let updateExpressionList newList =
                let
                  e2'         = replaceE__ e2 <| EList ws5 newList ws6 Nothing ws7
                  eAppConcat' = replaceE__ eAppConcat <| EApp ws3 eConcat [e2'] ws4
                  main'       = replaceE__ main <| EApp ws1 e1 [eAppConcat'] ws2
                in
                if ws1 == "" then addPrecedingWhitespace "\n\n" main'
                else if ws1 == "\n" then addPrecedingWhitespace "\n" main'
                else main'
              in
              Just (SvgConcat oldList updateExpressionList)

            _ -> Nothing
        _     -> Nothing
    _         -> Nothing

-- very similar to above
maybeBlobs : Exp -> Maybe MainExp
maybeBlobs main =
  case main.val.e__ of
    EApp ws1 eBlobs [eArgs] ws2 ->
      case (eBlobs.val.e__, eArgs.val.e__) of
        (EVar _ "blobs", EList ws5 oldList ws6 Nothing ws7) ->
          let rebuildExp newBlobExpList =
            let newExpList = List.map fromBlobExp newBlobExpList in
            let
              eArgs' = replaceE__ eArgs <| EList ws5 newExpList ws6 Nothing ws7
              main'  = replaceE__ main <| EApp ws1 eBlobs [eArgs'] ws2
            in
            if ws1 == "" then addPrecedingWhitespace "\n\n" main'
            else if ws1 == "\n" then addPrecedingWhitespace "\n" main'
            else main'
          in
          let blobs = List.map toBlobExp oldList in
          Just (Blobs blobs rebuildExp)

        _     -> Nothing
    _         -> Nothing

toBlobExp : Exp -> BlobExp
toBlobExp e =
  case e.val.e__ of
    EVar _ x -> varBlob e x
    EApp _ eWith [eBounds, eFunc] _ ->
      case (eWith.val.e__) of
        EVar _ "with" ->
          case eFunc.val.e__ of
            EVar _ x -> NiceBlob e (WithBoundsBlob (eBounds, x, []))
            EApp _ eF eArgs _ ->
              case eF.val.e__ of
                EVar _ f -> NiceBlob e (WithBoundsBlob (eBounds, f, eArgs))
                _        -> OtherBlob e
            _ -> OtherBlob e
        _ -> OtherBlob e
    EApp _ eFunc eArgs _ ->
      case eFunc.val.e__ of
        EVar _ f -> NiceBlob e (CallBlob (f, eArgs))
        _        -> OtherBlob e
    _ -> OtherBlob e

fromBlobExp : BlobExp -> Exp
fromBlobExp be =
  case be of
    OtherBlob e  -> e
    NiceBlob e _ -> e

randomColor model = eConst0 (toFloat model.randomColor) dummyLoc

randomColor1 model = eConst (toFloat model.randomColor) dummyLoc

{-
randomColorWithSlider model =
  withDummyPos (EConst "" (toFloat model.randomColor) dummyLoc colorNumberSlider)

randomColor1WithSlider model =
  withDummyPos (EConst " " (toFloat model.randomColor) dummyLoc colorNumberSlider)
-}

-- when line is snapped, not enforcing the angle in code
addLineToCodeAndRun old click2 click1 =
  let ((_,(x2,y2)),(_,(x1,y1))) = (click2, click1) in
  let (xb, yb) = View.snapLine old.keysDown click2 click1 in
  let color =
    if old.tool == HelperLine
      then eStr "aqua"
      else randomColor old
  in
  let (f, args) =
    maybeGhost (old.tool == HelperLine)
       (eVar0 "line")
       (List.map eVar ["color","width","x1","y1","x2","y2"])
  in
  addToCodeAndRun "line" old
    [ makeLet ["x1","y1","x2","y2"] (makeInts [x1,y1,xb,yb])
    , makeLet ["color", "width"]
              [ color , eConst 5 dummyLoc ]
    ] f args

{- using variables x1/x2/y1/y2 instead of left/top/right/bot:

  let (f, args) =
    maybeGhost (old.toolType == HelperLine)
       (eVar0 "line")
       (eStr color :: eStr "5" :: List.map eVar ["x1","y1","x2","y2"])
  in
  addToCodeAndRun "line" old
    [ makeLet ["x1","x2"] (makeInts [x1,xb])
    , makeLet ["y1","y2"] (makeInts [y1,yb])
    ] f args
-}

addRawRect old (_,pt2) (_,pt1) =
  let (xa, xb, ya, yb) = View.boundingBox pt2 pt1 in
  let (x, y, w, h) = (xa, ya, xb - xa, yb - ya) in
  addToCodeAndRun "rect" old
    [ makeLet ["x","y","w","h"] (makeInts [x,y,w,h])
    , makeLet ["color","rot"] [randomColor old, eConst 0 dummyLoc] ]
    (eVar0 "rawRect")
    [ eVar "color", eConst 360 dummyLoc, eConst 0 dummyLoc
    , eVar "x", eVar "y", eVar "w", eVar "h", eVar "rot" ]

addRawSquare old (_,pt2) (_,pt1) =
  let (xa, xb, ya, yb) = View.squareBoundingBox pt2 pt1 in
  let (x, y, side) = (xa, ya, xb - xa) in
  addToCodeAndRun "square" old
    [ makeLet ["x","y","side"] (makeInts [x,y,side])
    , makeLet ["color","rot"] [randomColor old, eConst 0 dummyLoc] ]
    (eVar0 "rawRect")
    [ eVar "color", eConst 360 dummyLoc, eConst 0 dummyLoc
    , eVar "x", eVar "y", eVar "side", eVar "side", eVar "rot" ]

addStretchyRect old (_,pt2) (_,pt1) =
  let (xMin, xMax, yMin, yMax) = View.boundingBox pt2 pt1 in
  addToCodeAndRun "rect" old
    [ makeLetAs "bounds" ["left","top","right","bot"] (makeInts [xMin,yMin,xMax,yMax])
    , makeLet ["color"] [randomColor1 old] ]
    (eVar0 "rectangle")
    [eVar "color", eConst 360 dummyLoc, eConst 0 dummyLoc, eConst 0 dummyLoc, eVar "bounds"]

addStretchySquare old (_,pt2) (_,pt1) =
  let (xMin, xMax, yMin, _) = View.squareBoundingBox pt2 pt1 in
  let side = (xMax - xMin) in
  addToCodeAndRun "square" old
    [ makeLet ["left","top","side"] (makeInts [xMin,yMin,side])
    , makeLet ["bounds"] [eList (listOfRaw ["left","top","(+ left side)","(+ top side)"]) Nothing]
    , makeLet ["rot"] [eConst 0 dummyLoc]
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 0 dummyLoc] ]
    (eVar0 "rectangle")
    (List.map eVar ["color","strokeColor","strokeWidth","rot","bounds"])

addRawOval old (_,pt2) (_,pt1) =
  let (xa, xb, ya, yb) = View.boundingBox pt2 pt1 in
  let (rx, ry) = ((xb-xa)//2, (yb-ya)//2) in
  let (cx, cy) = (xa + rx, ya + ry) in
  addToCodeAndRun "ellipse" old
    [ makeLet ["cx","cy","rx","ry"] (makeInts [cx,cy,rx,ry])
    , makeLet ["color","rot"] [randomColor old, eConst 0 dummyLoc] ]
    (eVar0 "rawEllipse")
    [ eVar "color", eConst 360 dummyLoc, eConst 0 dummyLoc
    , eVar "cx", eVar "cy", eVar "rx", eVar "ry", eVar "rot" ]

addRawCircle old (_,pt2) (_,pt1) =
  let (xa, xb, ya, yb) = View.squareBoundingBox pt2 pt1 in
  let r = (xb-xa)//2 in
  let (cx, cy) = (xa + r, ya + r) in
  addToCodeAndRun "circle" old
    [ makeLet ["cx","cy","r"] (makeInts [cx,cy,r])
    , makeLet ["color"] [randomColor1 old] ]
    (eVar0 "rawCircle")
    [ eVar "color", eConst 360 dummyLoc, eConst 0 dummyLoc
    , eVar "cx", eVar "cy", eVar "r" ]

addStretchyOval old (_,pt2) (_,pt1) =
  let (xa, xb, ya, yb) = View.boundingBox pt2 pt1 in
  addToCodeAndRun "ellipse" old
    [ makeLetAs "bounds" ["left","top","right","bot"] (makeInts [xa,ya,xb,yb])
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 0 dummyLoc] ]
    (eVar0 "oval")
    (List.map eVar ["color","strokeColor","strokeWidth","bounds"])

addStretchyCircle old (_,pt2) (_,pt1) =
  let (left, right, top, _) = View.squareBoundingBox pt2 pt1 in
  addToCodeAndRun "circle" old
    [ makeLet ["left", "top", "r"] (makeInts [left, top, (right-left)//2])
    , makeLet ["bounds"]
        [eList [eVar0 "left", eVar "top", eRaw "(+ left (* 2! r))", eRaw "(+ top (* 2! r))"] Nothing]
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 0 dummyLoc] ]
    (eVar0 "oval")
    (List.map eVar ["color","strokeColor","strokeWidth","bounds"])

addHelperDotToCodeAndRun old (_,(cx,cy)) =
  -- style matches center of attr crosshairs (View.zoneSelectPoint_)
  let r = 6 in
  let (f, args) =
    ghost (eVar0 "circle")
          (eStr "aqua" :: List.map eVar ["cx","cy","r"])
  in
  addToCodeAndRun "helperDot" old
    [ makeLet ["cx","cy","r"] (makeInts [cx,cy,r]) ]
    f args

{-
maybeFreeze n =
    then toString n ++ "!"
    else toString n
-}

maybeThaw n =
  if n == 0 || n == 1
    then toString n
    else toString n ++ "?"

maybeThaw0 s = if s == "0" then s else s ++ "?"

{-
qMark n  = toString n ++ "?"
qMarkLoc = dummyLoc_ thawed
-}

addPolygonToCodeAndRun stk old points =
  case stk of
    Raw      -> addRawPolygon old points
    Stretchy -> addStretchablePolygon old points
    Sticky   -> addStickyPolygon old points

addRawPolygon old keysAndPoints =
  let points = List.map snd keysAndPoints in
  let sPts =
    Utils.bracks <| Utils.spaces <|
      flip List.map (List.reverse points) <| \(x,y) ->
        let xStr = toString x in
        let yStr = toString y in
        Utils.bracks (Utils.spaces [xStr,yStr])
  in
  addToCodeAndRun "polygon" old
    [ makeLet ["pts"] [eRaw sPts]
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 2 dummyLoc]
    ]
    (eVar0 "rawPolygon")
    [ eVar "color", eVar "strokeColor", eVar "strokeWidth"
    , eVar "pts", eConst 0 dummyLoc ]

addStretchablePolygon old keysAndPoints =
  let points = List.map snd keysAndPoints in
  let (xMin, xMax, yMin, yMax) = View.boundingBoxOfPoints points in
  let (width, height) = (xMax - xMin, yMax - yMin) in
  let sPcts =
    Utils.bracks <| Utils.spaces <|
      flip List.map (List.reverse points) <| \(x,y) ->
        let xPct = (toFloat x - toFloat xMin) / toFloat width in
        let yPct = (toFloat y - toFloat yMin) / toFloat height in
        let xStr = maybeThaw xPct in
        let yStr = maybeThaw yPct in
        Utils.bracks (Utils.spaces [xStr,yStr])
  in
  addToCodeAndRun "polygon" old
    [ makeLetAs "bounds" ["left","top","right","bot"] (makeInts [xMin,yMin,xMax,yMax])
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 2 dummyLoc]
    , makeLet ["pcts"] [eRaw sPcts] ]
    (eVar0 "stretchyPolygon")
    (List.map eVar ["bounds","color","strokeColor","strokeWidth","pcts"])

addStickyPolygon old keysAndPoints =
  let points = List.map snd keysAndPoints in
  let (xMin, xMax, yMin, yMax) = View.boundingBoxOfPoints points in
  let (width, height) = (xMax - xMin, yMax - yMin) in
  let sOffsets =
    Utils.bracks <| Utils.spaces <|
      flip List.map (List.reverse points) <| \(x,y) ->
        let
          (dxLeft, dxRight) = (x - xMin, x - xMax)
          (dyTop , dyBot  ) = (y - yMin, y - yMax)
          xOff = if dxLeft <= abs dxRight
                   then Utils.bracks (Utils.spaces ["left", maybeThaw0 (toString dxLeft)])
                   else Utils.bracks (Utils.spaces ["right", maybeThaw0 (toString dxRight)])
          yOff = if dyTop <= abs dyBot
                   then Utils.bracks (Utils.spaces ["top", maybeThaw0 (toString dyTop)])
                   else Utils.bracks (Utils.spaces ["bot", maybeThaw0 (toString dyBot)])
        in
        Utils.bracks (Utils.spaces [xOff,yOff])
  in
  addToCodeAndRun "polygon" old
    [ makeLetAs "bounds" ["left","top","right","bot"] (makeInts [xMin,yMin,xMax,yMax])
    , makeLet ["color","strokeColor","strokeWidth"]
              [randomColor old, eConst 360 dummyLoc, eConst 2 dummyLoc]
    , makeLet ["offsets"] [eRaw sOffsets] ]
    (eVar0 "stickyPolygon")
    (List.map eVar ["bounds","color","strokeColor","strokeWidth","offsets"])

strPoint strX strY (x,y) = Utils.spaces [strX x, strY y]

addPathToCodeAndRun : ShapeToolKind -> Model -> List (KeysDown, (Int, Int)) -> Model
addPathToCodeAndRun stk old keysAndPoints =
  case stk of
    Raw      -> addAbsolutePath old keysAndPoints
    Stretchy -> addStretchyPath old keysAndPoints
    Sticky   -> addStretchyPath old keysAndPoints -- TODO

pathCommands strX strY keysAndPoints =
  let strPt = strPoint strX strY in
  let keysAndPoints_ = List.reverse keysAndPoints in
  let (_,firstClick) = Utils.head_ keysAndPoints_ in
  let (_,lastClick) = Utils.last_ keysAndPoints_ in
  let (extraLets, firstCmd, lastPoint) =
    if firstClick /= lastClick
    then ([], "'M' " ++ strPt firstClick, strPt firstClick)
    else
      let extraLets =
        [ makeLet
           ["x0", "y0"]
           [ eVar0 (strX (fst firstClick)), eVar (strY (snd firstClick)) ] ]
      in
      (extraLets, "'M' x0 y0", "x0 y0")
  in
  let remainingCmds =
    let foo list0 = case list0 of
      [] -> []

      (modifiers1,click1) :: list1 ->

        if modifiers1 == Keys.q then
          case list1 of
            (modifiers2,click2) :: list2 ->
              case (click2 == firstClick, list2) of
                (True, []) -> [Utils.spaces ["'Q'", strPt click1, lastPoint]]
                (False, _) -> (Utils.spaces ["'Q'", strPt click1, strPt click2]) :: foo list2
                (True, _)  -> Debug.crash "addPath Q1"
            _ -> Debug.crash "addPath Q2"

        else if modifiers1 == Keys.c then
          case list1 of
            (modifiers2,click2) :: (modifiers3,click3) :: list3 ->
              case (click3 == firstClick, list3) of
                (True, []) -> [Utils.spaces ["'C'", strPt click1, strPt click2, lastPoint]]
                (False, _) -> (Utils.spaces ["'C'", strPt click1, strPt click2, strPt click3]) :: foo list3
                (True, _)  -> Debug.crash "addPath C1"
            _ -> Debug.crash "addPath C2"

        else
          case (click1 == firstClick, list1) of
            (True, []) -> ["'Z'"]
            (False, _) -> (Utils.spaces ["'L'", strPt click1]) :: foo list1
            (True, _)  -> Debug.crash "addPath ZL"
    in
    foo (Utils.tail_ keysAndPoints_)
  in
  let sD = Utils.bracks (Utils.spaces (firstCmd :: remainingCmds)) in
  (extraLets, sD)

addAbsolutePath old keysAndPoints =
  let (extraLets, sD) = pathCommands toString toString keysAndPoints in
  addToCodeAndRun "path" old
    ([ makeLet ["strokeColor","strokeWidth","color"]
               [randomColor old, eConst 5 dummyLoc, randomColor1 old] ]
    ++ extraLets
    ++ [makeLet ["d"] [eVar sD] ])
    (eVar0 "rawPath")
    [ eVar "color", eVar "strokeColor", eVar "strokeWidth"
    , eVar "d", eConst 0 dummyLoc ]

addStretchyPath old keysAndPoints =
  let points = List.map snd keysAndPoints in
  let (xMin, xMax, yMin, yMax) = View.boundingBoxOfPoints points in
  let (width, height) = (toFloat (xMax - xMin), toFloat (yMax - yMin)) in
  let strX x = maybeThaw (toFloat (x - xMin) / width) in
  let strY y = maybeThaw (toFloat (y - yMin) / height) in
  let (extraLets, sD) = pathCommands strX strY keysAndPoints in
  addToCodeAndRun "path" old
    ([ makeLetAs "bounds" ["left","top","right","bot"] (makeInts [xMin,yMin,xMax,yMax])
     , makeLet ["strokeColor","strokeWidth","color"]
               [ randomColor old, eConst 5 dummyLoc, randomColor1 old ] ]
     ++ extraLets
     ++ [ makeLet ["dPcts"] [eVar sD] ])
    (eVar0 "stretchyPath")
    (List.map eVar ["bounds","color","strokeColor","strokeWidth","dPcts"])

addStickyPath old keysAndPoints =
  Debug.crash "TODO: addStickyPath"

addLambdaToCodeAndRun old (_,pt2) (_,pt1) =
  let func =
    let (selectedIdx, exps) = old.lambdaTools in
    Utils.geti selectedIdx exps
  in
  let (xa, xb, ya, yb) =
    if old.keysDown == Keys.shift
      then View.squareBoundingBox pt2 pt1
      else View.boundingBox pt2 pt1
  in

  {- this version adds a call to main: -}

  let bounds = eList (makeInts [xa,ya,xb,yb]) Nothing in
  let args = [] in
  let eNew =
    withDummyPos (EApp "\n  " (eVar0 "with") [ bounds, func ] "") in
  -- TODO refactor Program to keep (f,args) in sync with exp
  let newBlob = withBoundsBlob eNew (bounds, "XXXXX", args) in
  let (defs, mainExp) = splitExp old.inputExp in
  let mainExp' = addToMainExp newBlob mainExp in
  let code = unparse (fuseExp (defs, mainExp')) in

  upstate Run
    { old | code = code
          , mouseMode = MouseNothing }

  {- this version adds the call inside a new top-level definition:

  addToCodeAndRun funcName old
    [ makeLet ["left","top","right","bot"] (makeInts [xa,ya,xb,yb])
    , makeLet ["bounds"] [eList (listOfVars ["left","top","right","bot"]) Nothing]
    ]
    (eVar0 "with") [ eVar "bounds" , eVar funcName ]

  -}

addToCodeAndRun newShapeKind old newShapeLocals newShapeFunc newShapeArgs =

  let tmp = newShapeKind ++ toString old.genSymCount in
  let newDef = makeNewShapeDef old newShapeKind tmp newShapeLocals newShapeFunc newShapeArgs in
  let (defs, mainExp) = splitExp old.inputExp in
  let defs' = defs ++ [newDef] in
  let eNew = withDummyPos (EVar "\n  " tmp) in
  let mainExp' = addToMainExp (varBlob eNew tmp) mainExp in
  let code = unparse (fuseExp (defs', mainExp')) in

  upstate Run
    { old | code = code
          , genSymCount = old.genSymCount + 1
          , mouseMode = MouseNothing }

makeNewShapeDef model newShapeKind name locals func args =
  let newShapeName = withDummyRange (PVar " " name noWidgetDecl) in
  let recurse locals =
    case locals of
      [] ->
        let multi = -- check if (func args) returns List SVG or SVG
          case model.tool of
            Lambda -> True
            _ -> False
        in
        if multi then
          withDummyPos (EApp "\n    " func args "")
        else
          let app = withDummyPos (EApp " " func args "") in
          withDummyPos (EList "\n    " [app] "" Nothing " ")
      (p,e)::locals' -> withDummyPos (ELet "\n  " Let False p e (recurse locals') "")
  in
  ("\n\n", newShapeName, recurse locals, "")

makeLet : List Ident -> List Exp -> (Pat, Exp)
makeLet vars exps =
  case (vars, exps) of
    ([x],[e])     -> (pVar x, e)
    (x::xs,e::es) -> let ps = List.map pVar xs in
                     let p = pVar0 x in
                     (pList (p::ps), eList (e::es) Nothing)
    _             -> Debug.crash "makeLet"

makeLetAs : Ident -> List Ident -> List Exp -> (Pat, Exp)
makeLetAs x vars exps =
  let (p, e) = makeLet vars exps in
  (pAs x p, e)

makeInts : List Int -> List Exp
makeInts nums =
  case nums of
    []    -> Debug.crash "makeInts"
    [n]   -> [eConst0 (toFloat n) dummyLoc]
    n::ns -> let e = eConst0 (toFloat n) dummyLoc in
             let es = List.map (\n' -> eConst (toFloat n') dummyLoc) ns in
             e::es

addToMainExp : BlobExp -> MainExp -> MainExp
addToMainExp newBlob mainExp =
  case mainExp of
    SvgConcat shapes f -> SvgConcat (shapes ++ [fromBlobExp newBlob]) f
    Blobs shapes f     -> Blobs (shapes ++ [newBlob]) f
    OtherExp main ->
      let ws = "\n" in -- TODO take main into account
      OtherExp <| withDummyPos <|
        EApp ws (eVar0 "addShapes") [fromBlobExp newBlob, main] ""

maybeGhost b f args =
  if b
    then (eVar0 "ghost", [ withDummyPos (EApp " " f args "") ])
    else (f, args)

ghost = maybeGhost True

switchToCursorTool old =
  { old | mouseMode = MouseNothing , tool = Cursor }


--------------------------------------------------------------------------------
-- Group Blobs

computeSelectedBlobsAndBounds : Model -> Dict Int (NumTr, NumTr, NumTr, NumTr)
computeSelectedBlobsAndBounds model =
  let tree = snd model.slate in
  Dict.map
     (\blobId nodeId ->
       case Dict.get nodeId tree of

         -- refactor the following cases for readability

         Just (LangSvg.SvgNode "BOX" nodeAttrs _) ->
           let get attr = ValueBasedTransform.maybeFindAttr nodeId "BOX" attr nodeAttrs in
           case List.map .v_ [get "LEFT", get "TOP", get "RIGHT", get "BOT"] of
             [VConst left, VConst top, VConst right, VConst bot] ->
               (left, top, right, bot)
             _ -> Debug.crash "computeSelectedBlobsAndBounds"

         Just (LangSvg.SvgNode "OVAL" nodeAttrs _) ->
           let get attr = ValueBasedTransform.maybeFindAttr nodeId "OVAL" attr nodeAttrs in
           case List.map .v_ [get "LEFT", get "TOP", get "RIGHT", get "BOT"] of
             [VConst left, VConst top, VConst right, VConst bot] ->
               (left, top, right, bot)
             _ -> Debug.crash "computeSelectedBlobsAndBounds"

         Just (LangSvg.SvgNode "g" nodeAttrs _) ->
           case View.maybeFindBounds nodeAttrs of
             Just bounds -> bounds
             Nothing     -> Debug.crash "computeSelectedBlobsAndBounds"

         Just (LangSvg.SvgNode "line" nodeAttrs _) ->
           let get attr = ValueBasedTransform.maybeFindAttr nodeId "line" attr nodeAttrs in
           case List.map .v_ [get "x1", get "y1", get "x2", get "y2"] of
             [VConst x1, VConst y1, VConst x2, VConst y2] ->
               (minNumTr x1 x2, minNumTr y1 y2, maxNumTr x1 x2, maxNumTr y1 y2)
             _ -> Debug.crash "computeSelectedBlobsAndBounds"

         -- "ellipse" and "circle" aren't handled nicely by grouping

         Just (LangSvg.SvgNode "ellipse" nodeAttrs _) ->
           let get attr = ValueBasedTransform.maybeFindAttr nodeId "ellipse" attr nodeAttrs in
           case List.map .v_ [get "cx", get "cy", get "rx", get "ry"] of
             [VConst cx, VConst cy, VConst rx, VConst ry] ->
               (cx `minusNumTr` rx, cy `minusNumTr` ry, cx `plusNumTr` rx, cy `plusNumTr` ry)
             _ -> Debug.crash "computeSelectedBlobsAndBounds"

         Just (LangSvg.SvgNode "circle" nodeAttrs _) ->
           let get attr = ValueBasedTransform.maybeFindAttr nodeId "circle" attr nodeAttrs in
           case List.map .v_ [get "cx", get "cy", get "r"] of
             [VConst cx, VConst cy, VConst r] ->
               (cx `minusNumTr` r, cy `minusNumTr` r, cx `plusNumTr` r, cy `plusNumTr` r)
             _ -> Debug.crash "computeSelectedBlobsAndBounds"

         _ -> Debug.crash "computeSelectedBlobsAndBounds"
     )
     model.selectedBlobs

selectedBlobsToSelectedNiceBlobs : Model -> List BlobExp -> List (Int, Exp, NiceBlob)
selectedBlobsToSelectedNiceBlobs model blobs =
  let selectedExps =
    List.filter (flip Dict.member model.selectedBlobs << fst)
                (Utils.zip [1 .. List.length blobs] blobs)
  in
  Utils.filterJusts <|
    List.map
       (\(i, be) ->
         case be of
           NiceBlob e niceBlob -> Just (i, e, niceBlob)
           _                   -> Nothing
       )
       selectedExps

matchesAnySelectedVarBlob_ : List (Int, Exp, NiceBlob) -> TopDef -> Maybe Ident
matchesAnySelectedVarBlob_ selectedNiceBlobs def =
  let findBlobForIdent y =
    let foo (_,_,niceBlob) =
      case niceBlob of
        VarBlob x        -> x == y
        WithBoundsBlob _ -> False
        CallBlob _       -> False
    in
    case Utils.findFirst foo selectedNiceBlobs of
      Just (_, _, VarBlob x) -> Just x
      _                      -> Nothing
  in
  let (_,p,_,_) = def in
  case p.val of
    PVar _ y _  -> findBlobForIdent y
    PAs _ y _ _ -> findBlobForIdent y
    _           -> Nothing

matchesAnySelectedVarBlob selectedNiceBlobs def =
  case matchesAnySelectedVarBlob_ selectedNiceBlobs def of
    Just _  -> True
    Nothing -> False

-- TODO refactor/combine with above
matchesAnySelectedCallBlob_ : List (Int, Exp, NiceBlob) -> TopDef -> Maybe Ident
matchesAnySelectedCallBlob_ selectedNiceBlobs def =
  let findBlobForIdent y =
    let foo (_,_,niceBlob) =
      case niceBlob of
        VarBlob _                -> False
        WithBoundsBlob (_, f, _) -> f == y
        CallBlob (f, _)          -> f == y
    in
    case Utils.findFirst foo selectedNiceBlobs of
      Just (_, _, CallBlob (f, _))          -> Just f
      Just (_, _, WithBoundsBlob (_, f, _)) -> Just f
      _                                     -> Nothing
  in
  let (_,p,_,_) = def in
  case p.val of
    PVar _ y _  -> findBlobForIdent y
    PAs _ y _ _ -> findBlobForIdent y
    _           -> Nothing

matchesAnySelectedCallBlob selectedNiceBlobs def =
  case matchesAnySelectedCallBlob_ selectedNiceBlobs def of
    Just _  -> True
    Nothing -> False

-- TODO
matchesAnySelectedBlob selectedNiceBlobs def =
  case matchesAnySelectedVarBlob_ selectedNiceBlobs def of
    Just _  -> True
    Nothing ->
      case matchesAnySelectedCallBlob_ selectedNiceBlobs def of
        Just _  -> True
        Nothing -> False

groupSelectedBlobs model defs blobs f =
  let n = List.length blobs in
  let selectedNiceBlobs = selectedBlobsToSelectedNiceBlobs model blobs in
  let newGroup = "newGroup" ++ toString model.genSymCount in
  let (defs', blobs') = groupAndRearrange model newGroup defs blobs selectedNiceBlobs in
  -- let code' = Debug.log "newGroup" <| unparse (fuseExp (defs', Blobs blobs' f)) in
  let code' = unparse (fuseExp (defs', Blobs blobs' f)) in
  upstate Run
    { model | code = code'
            , genSymCount = model.genSymCount + 1
            , selectedBlobs = Dict.empty
            }

groupAndRearrange model newGroup defs blobs selectedNiceBlobs =
  let selectedBlobsAndBounds = computeSelectedBlobsAndBounds model in
  let (pluckedBlobs, beforeBlobs, afterBlobs) =
    let indexedBlobs = Utils.zip [1 .. List.length blobs] blobs in
    let matches (i,_) = Dict.member i model.selectedBlobs in
    let (plucked_, before_, after_) = pluckFromList matches indexedBlobs in
    (List.map snd plucked_, List.map snd before_, List.map snd after_)
  in
  let defs' =
    let matches = matchesAnySelectedBlob selectedNiceBlobs in
    let (pluckedDefs, beforeDefs, afterDefs) =
      -- TODO make safe again
      -- let (plucked, before, after) = pluckFromList matches defs in
      let (plucked, before, after) = unsafePluckFromList matches defs in
      let getExps = List.map (\(_,_,e,_) -> e) in
      let (beforeInside, beforeOutside) =
        List.foldr
           (\beforeDef (acc1,acc2) ->
             -- if needed, could split a multi-binding into smaller chunks
             let (_,p,_,_) = beforeDef in
             let vars = varsOfPat p in
             let someVarAppearsIn e = List.any (\x -> occursFreeIn x e) vars in
             let noVarAppearsIn e = List.all (\x -> not (occursFreeIn x e)) vars in
             if List.any someVarAppearsIn (getExps (plucked ++ acc1)) &&
                List.all noVarAppearsIn (getExps (after ++ acc2))
             then (beforeDef :: acc1, acc2)
             else (acc1, beforeDef :: acc2)
           )
           ([],[])
           before
      in
      (beforeInside ++ plucked, beforeOutside, after)
    in
    let selectedBlobIndices = Dict.keys model.selectedBlobs in
    let (left, top, right, bot) =
      case selectedBlobIndices of
        [] -> Debug.crash "groupAndRearrange: shouldn't get here"
        i::is ->
          let init = Utils.justGet i selectedBlobsAndBounds in
          let foo j (left,top,right,bot) =
            let (a,b,c,d) = Utils.justGet j selectedBlobsAndBounds in
            (minNumTr left a, minNumTr top b, maxNumTr right c, maxNumTr bot d)
          in
          List.foldl foo init is
    in
    let (width, height) = (fst right - fst left, fst bot - fst top) in
    let scaleX  = scaleXY  "left" "right" left width in
    let scaleY  = scaleXY  "top"  "bot"   top  height in
    let offsetX = offsetXY "left" "right" left right in
    let offsetY = offsetXY "top"  "bot"   top  bot in
    let eSubst =
      -- the spaces inserted by calls to offset*/scale* work best
      -- when the source expressions being rewritten are of the form
      --   (let [a b c d] [na nb nc nd] ...)
      let foo i acc =
        let (a,b,c,d) = Utils.justGet i selectedBlobsAndBounds in
        if model.keysDown == Keys.shift then
          acc |> offsetX "" a |> offsetY " " b |> offsetX " " c |> offsetY " " d
        else
          -- acc |> scaleX "" a |> scaleY " " b |> scaleX " " c |> scaleY " " d
          acc |> scaleX " " a |> scaleY " " b |> scaleX " " c |> scaleY " " d
      in
      List.foldl foo Dict.empty selectedBlobIndices
    in
    let groupDefs =
      [ ( "\n  "
        , pAs "bounds" (pList (listOfPVars ["left", "top", "right", "bot"]))
        , eList (listOfNums [fst left, fst top, fst right, fst bot]) Nothing
        , "")
      ]
    in
    let listBoundedGroup =
      let pluckedBlobs' =
        List.map (LangUnparser.replacePrecedingWhitespace " " << fromBlobExp)
                 pluckedBlobs
      in
      withDummyPos <| EList "\n\n  "
         [ withDummyPos <| EApp " "
             (eVar0 "group")
             [ eVar "bounds"
             , withDummyPos <| EApp " "
                 (eVar0 "concat")
                 [withDummyPos <| EList " " pluckedBlobs' "" Nothing " "]
                 ""
             ]
             ""
         ]
         "" Nothing " "
    in
    let pluckedDefs' =
      let tab = "  " in
      List.map (\(ws1,p,e,ws2) -> (ws1 ++ tab, p, LangUnparser.indent tab e, ws2))
               pluckedDefs
    in
    let newGroupExp =
      applyESubst eSubst <|
        fuseExp (groupDefs ++ pluckedDefs', OtherExp listBoundedGroup)
          -- TODO flag for fuseExp to insert lets instead of defs
    in
    let newDef = ("\n\n", pVar newGroup, newGroupExp, "") in
    -- beforeDefs ++ [newDef] ++ afterDefs
    beforeDefs ++ afterDefs ++ [newDef]
  in
  let blobs' =
    let newBlob = varBlob (withDummyPos (EVar "\n  " newGroup)) newGroup in
    beforeBlobs ++ [newBlob] ++ afterBlobs
  in
  (defs', blobs')

-- TODO maybe stop using this to keep total ordering
pluckFromList pred xs =
  let foo x (plucked, before, after) =
    case (pred x, plucked) of
      (True, _)   -> (plucked ++ [x], before, after)
      (False, []) -> (plucked, before ++ [x], after)
      (False, _)  -> (plucked, before, after ++ [x])
  in
  List.foldl foo ([],[],[]) xs

unsafePluckFromList pred xs =
  let (plucked, before, after) = pluckFromList pred (List.reverse xs) in
  (List.reverse plucked, List.reverse after, List.reverse before)

scaleXY start end startVal widthOrHeight ws (n,t) eSubst =
  case t of
    TrLoc (locid,_,_) ->
      let pct = (n - fst startVal) / widthOrHeight in
      let app =
        if pct == 0 then ws ++ start
        else if pct == 1 then ws ++ end
        else
          ws ++ Utils.parens (Utils.spaces ["scaleBetween", start, end, toString pct]) in
      Dict.insert locid (eRaw__ "" app) eSubst
    _ ->
      eSubst

-- TODO for scaleXY and offsetXY, forgo function call when on
-- boundaries to improve readability of generated code
-- (falls back in on little prelude encoding)

offsetXY base1 base2 baseVal1 baseVal2 ws (n,t) eSubst =
  case t of
    TrLoc (locid,_,_) ->
      let (off1, off2) = (n - fst baseVal1, n - fst baseVal2) in
      let (base, off) =
        if off1 <= abs off2 then (base1, off1) else (base2, off2) in
      let app =
        ws ++ Utils.parens (Utils.spaces
                [ "evalOffset"
                , Utils.bracks (Utils.spaces [base, toString off])]) in
      Dict.insert locid (eRaw__ "" app) eSubst
    _ ->
      eSubst

varsOfPat : Pat -> List Ident
varsOfPat pat =
  case pat.val of
    PConst _ _              -> []
    PBase _ _               -> []
    PVar _ x _              -> [x]
    PList _ ps _ Nothing _  -> List.concatMap varsOfPat ps
    PList _ ps _ (Just p) _ -> List.concatMap varsOfPat (p::ps)
    PAs _ x _ p             -> x::(varsOfPat p)

-- TODO for now, just checking occursIn
occursFreeIn : Ident -> Exp -> Bool
occursFreeIn x e =
  let vars =
    foldExpViaE__ (\e__ acc ->
      case e__ of
        EVar _ x -> Set.insert x acc
        _        -> acc
      ) Set.empty e
  in
  Set.member x vars


--------------------------------------------------------------------------------
-- Abstract Blob

selectedBlobsToSelectedVarBlobs : Model -> List BlobExp -> List (Int, Exp, Ident)
selectedBlobsToSelectedVarBlobs model blobs =
  List.concatMap
     (\(i,e,niceBlob) ->
       case niceBlob of
         VarBlob x        -> [(i, e, x)]
         WithBoundsBlob _ -> []
         CallBlob _       -> []
     )
     (selectedBlobsToSelectedNiceBlobs model blobs)

abstractSelectedBlobs model =
  let (defs,mainExp) = splitExp model.inputExp in
  case mainExp of
    Blobs blobs f ->
      -- silently ignoring WithBoundsBlobs
      let selectedVars = selectedBlobsToSelectedVarBlobs model blobs in
      let (defs',blobs') = List.foldl abstractOne (defs, blobs) selectedVars in
      let code' = unparse (fuseExp (defs', Blobs blobs' f)) in
      upstate Run
        { model | code = code'
                , selectedBlobs = Dict.empty
                }
    _ ->
      model

abstractOne (i, eBlob, x) (defs, blobs) =

  let (pluckedDefs, beforeDefs, afterDefs) =
    pluckFromList (matchesAnySelectedVarBlob [(i, eBlob, VarBlob x)]) defs in

  let (pluckedBlobs, beforeBlobs, afterBlobs) =
    let matches (j,_) = i == j in
    let (plucked, before, after) =
      pluckFromList matches (Utils.zip [1 .. List.length blobs] blobs) in
    (List.map snd plucked, List.map snd before, List.map snd after) in

  case (pluckedDefs, pluckedBlobs) of

    ([(ws1,p,e,ws2)], [NiceBlob _ (VarBlob x)]) ->

      let (e', mapping) = collectUnfrozenConstants e in
      let (newDef, newBlob) =
        case findBoundsInMapping mapping of

          Just (restOfMapping, left, top, right, bot) ->
            let newFunc =
              let pBounds =
                let pVars = listOfPVars ["left", "top", "right", "bot"] in
                case restOfMapping of
                  [] -> pList0 pVars
                  _  -> pList  pVars
              in
              let params = listOfPVars (List.map fst restOfMapping) in
              withDummyPos (EFun " " (params ++ [pBounds]) e' "")
            in
            let eBounds = eList (listOfAnnotatedNums [left, top, right, bot]) Nothing in
            let newCall =
              let eBlah =
                case listOfAnnotatedNums1 (List.map snd restOfMapping) of
                  []   -> eVar x
                  args -> withDummyPos (EApp " " (eVar0 x) args "")
              in
              withDummyPos (EApp "\n  " (eVar0 "with") [eBounds, eBlah] "")
            in
            let newBlob = NiceBlob newCall (WithBoundsBlob (eBounds, x, [])) in
            ((ws1, p, newFunc, ws2), newBlob)

          Nothing ->
            let newFunc =
              let params = listOfPVars (List.map fst mapping) in
              withDummyPos (EFun " " params e' "")
            in
            let newBlob =
              case listOfAnnotatedNums1 (List.map snd mapping) of
                []   -> varBlob (eVar x) x
                args ->
                  let newCall = withDummyPos (EApp "\n  " (eVar0 x) args "") in
                  callBlob newCall (x, args)
            in
            ((ws1, p, newFunc, ws2), newBlob)
      in
      let defs' = beforeDefs ++ [newDef] ++ afterDefs in
      let blobs' = beforeBlobs ++ [newBlob] ++ afterBlobs in
      (defs', blobs')

    _ ->
      let _ = Debug.log "abstractOne: multiple defs..." in
      (defs, blobs)

collectUnfrozenConstants : Exp -> (Exp, List (Ident, AnnotatedNum))
collectUnfrozenConstants e =
  -- extra first pass, as a quick and simple way to approximate name clashes
  let (_, list0) = collectUnfrozenConstants_ Nothing e in
  let varCounts =
    List.foldl (\var acc ->
      case Dict.get var acc of
        Nothing    -> Dict.insert var 1 acc
        Just count -> Dict.insert var (1 + count) acc
      ) Dict.empty (List.map fst list0)
  in
  let (e', list) = collectUnfrozenConstants_ (Just varCounts) e in
  (removeRedundantBindings e', List.reverse list)

collectUnfrozenConstants_
     : Maybe (Dict Ident Int) -> Exp -> (Exp, List (Ident, AnnotatedNum))
collectUnfrozenConstants_ maybeVarCounts e =
  let foo e__ =
    let default = (e__, []) in
    case e__ of
      EConst ws n (locid, ann, x) wd ->
        if ann == unann || ann == thawed then
          if x == ""
          then default -- (EVar ws x, [("k" ++ toString locid, n)])
          else
            let addVar y = (EVar ws y, [(y, (n,ann,wd))]) in
            case maybeVarCounts of
              Nothing -> addVar x
              Just varCounts ->
                if Utils.justGet x varCounts == 1
                then addVar x
                else addVar (x ++ toString locid)
        else
          default
      _ ->
       default
  in
  -- two passes for ease of implementation
  let e' = mapExpViaExp__ (fst << foo) e in
  let mapping = foldExpViaE__ ((++) << snd << foo) [] e in
  (e', mapping)

findBoundsInMapping : List (Ident, a) -> Maybe (List (Ident, a), a, a, a, a)
findBoundsInMapping mapping =
  case mapping of
    ("left", left) :: ("top", top) :: ("right", right) :: ("bot", bot) :: rest ->
      Just (rest, left, top, right, bot)
    _ ->
      Nothing

removeRedundantBindings =
  mapExp <| \e ->
    case e.val.e__ of
      ELet _ _ _ p e1 e2 _ -> if redundantBinding (p, e1) then e2 else e
      _                    -> e

redundantBinding (p, e) =
  case (p.val, e.val.e__) of
    (PConst _ n, EConst _ n' _ _) -> n == n'
    (PBase _ bv, EBase _ bv')     -> bv == bv'
    (PVar _ x _, EVar _ x')       -> x == x'

    (PList _ ps _ Nothing _, EList _ es _ Nothing _) ->
      List.all redundantBinding (Utils.zip ps es)
    (PList _ ps _ (Just p) _, EList _ es _ (Just e) _) ->
      List.all redundantBinding (Utils.zip (p::ps) (e::es))

    _ -> False


--------------------------------------------------------------------------------
-- Delete Blobs

deleteSelectedBlobs model =
  let (defs,mainExp) = splitExp model.inputExp in
  case mainExp of
    Blobs blobs f ->
      let blobs' =
        Utils.filteri
           (\(i,_) -> not (Dict.member i model.selectedBlobs))
           blobs
      in
      let code' = unparse (fuseExp (defs, Blobs blobs' f)) in
      upstate Run
        { model | code = code'
              , selectedBlobs = Dict.empty
              }
    _ ->
      model


--------------------------------------------------------------------------------
-- Duplicate Blobs

duplicateSelectedBlobs model =
  let (defs,mainExp) = splitExp model.inputExp in
  case mainExp of
    Blobs blobs f ->
      let (nextGenSym, newDefs, newBlobs) =
        let selectedNiceBlobs = selectedBlobsToSelectedNiceBlobs model blobs in
        let (nextGenSym_, newDefs_, newVarBlobs_) =
          List.foldl
             (\def (k,acc1,acc2) ->
               if not (matchesAnySelectedVarBlob selectedNiceBlobs def)
               then (k, acc1, acc2)
               else
                 let (ws1,p,e,ws2) = def in
                 case p.val of
                   PVar ws x wd ->
                     let x' = x ++ "_copy" ++ toString k in
                     let acc1' = (ws1, { p | val = PVar ws x' wd }, e, ws2) :: acc1 in
                     let acc2' = varBlob (withDummyPos (EVar "\n  " x')) x' :: acc2 in
                     (1 + k, acc1', acc2')
                   _ ->
                     let _ = Debug.log "duplicateSelectedBlobs: weird..." () in
                     (k, acc1, acc2)
             )
             (model.genSymCount, [], [])
             defs
        in
        let newWithAndCallBlobs =
          List.concatMap
             (\(_,e,niceBlob) ->
               case niceBlob of
                 WithBoundsBlob _ -> [NiceBlob e niceBlob]
                 CallBlob _       -> [NiceBlob e niceBlob]
                 VarBlob _        -> []
             )
             selectedNiceBlobs
        in
        let newDefs = List.reverse newDefs_ in
        let newBlobs = List.reverse newVarBlobs_ ++ newWithAndCallBlobs in
        (nextGenSym_, newDefs, newBlobs)
      in
      let code' =
        let blobs' = blobs ++ newBlobs in
        let defs' = defs ++ newDefs in
        unparse (fuseExp (defs', Blobs blobs' f))
      in
      upstate Run
        { model | code = code'
                , genSymCount = List.length newBlobs + model.genSymCount
                }
    _ ->
      model

{-
shiftNum (n, t) = (30 + n, t)

shiftDownAndRight (left, top, right, bot) =
  (shiftNum left, shiftNum top, right, bot)
-}


--------------------------------------------------------------------------------
-- Merge Blobs

mergeSelectedBlobs model =
  let (defs,mainExp) = splitExp model.inputExp in
  case mainExp of
    Blobs blobs f ->
      let selectedVarBlobs = selectedBlobsToSelectedVarBlobs model blobs in
      if List.length selectedVarBlobs /= Dict.size model.selectedBlobs then
        model -- should display error caption for remaining selected blobs...
      else
        let (defs', blobs') = mergeSelectedVarBlobs model defs blobs selectedVarBlobs in
        let code' = unparse (fuseExp (defs', Blobs blobs' f)) in
        upstate Run
          { model | code = code'
                  , selectedBlobs = Dict.empty
                  }
    _ ->
      model

mergeSelectedVarBlobs model defs blobs selectedVarBlobs =

  let (pluckedDefs, beforeDefs, afterDefs) =
    let selectedNiceBlobs = List.map (\(i,e,x) -> (i, e, VarBlob x)) selectedVarBlobs in
    pluckFromList (matchesAnySelectedVarBlob selectedNiceBlobs) defs in

  let (pluckedBlobs, beforeBlobs, afterBlobs) =
    let matches (j,_) = Dict.member j model.selectedBlobs in
    let (plucked, before, after) =
      pluckFromList matches (Utils.zip [1 .. List.length blobs] blobs) in
    (List.map snd plucked, List.map snd before, List.map snd after) in

  let ((ws1,p,e,ws2),es) =
    case pluckedDefs of
      def::defs' -> (def, List.map (\(_,_,e,_) -> e) defs')
      []         -> Debug.crash "mergeSelectedVarBlobs: shouldn't get here" in

  case mergeExpressions e es of
    Nothing ->
      -- let _ = Debug.log "mergeExpressions Nothing" () in
      (defs, blobs)

    Just (_, []) ->
      let defs' = beforeDefs ++ [(ws1,p,e,ws2)] ++ afterDefs in
      let blobs' = beforeBlobs ++ [Utils.head_ pluckedBlobs] ++ afterBlobs in
      (defs', blobs')

    Just (eMerged, multiMapping) ->

      -- TODO treat bounds variables specially, as in abstract

      let newDef =
        let newFunc =
          let params = listOfPVars (List.map fst multiMapping) in
          withDummyPos (EFun " " params (removeRedundantBindings eMerged) "") in
        (ws1, p, newFunc, ws2) in

      let f =
        case p.val of
          PVar _ x _ -> x
          _          -> Debug.crash "mergeSelected: not var" in

      let newBlobs =
        case Utils.maybeZipN (List.map snd multiMapping) of
          Nothing -> Debug.crash "mergeSelected: no arg lists?"
          Just numLists ->
            -- let _ = Debug.log "numLists:" numLists in
            List.map
               (\nums ->
                  let args = listOfAnnotatedNums1 nums in
                  let e = withDummyPos <| EApp "\n  " (eVar0 f) args "" in
                  callBlob e (f, args)
               ) numLists in

      let defs' = beforeDefs ++ [newDef] ++ afterDefs in
      let blobs' = beforeBlobs ++ newBlobs ++ afterBlobs in
      (defs', blobs')

-- Merge 2+ expressions
mergeExpressions
    : Exp -> List Exp
   -> Maybe (Exp, List (Ident, List AnnotatedNum))
mergeExpressions eFirst eRest =
  let return e__ list =
    Just (replaceE__ eFirst e__, list) in

  case eFirst.val.e__ of

    EConst ws1 n loc wd ->
      let match eNext = case eNext.val.e__ of
        EConst _ nNext (_,annNext,_) wdNext -> Just (nNext, annNext, wdNext)
        _                                   -> Nothing
      in
      matchAllAndBind match eRest <| \restAnnotatedNums ->
        let (locid,ann,x) = loc in
        let allAnnotatedNums = (n,ann,wd) :: restAnnotatedNums in
        case Utils.dedup_ annotatedNumToComparable allAnnotatedNums of
          [_] -> return eFirst.val.e__ []
          _   ->
            let var = if x == "" then "k" ++ toString locid else x in
            -- let _ = Debug.log "var for merge: " (var, n::nums) in
            return (EVar ws1 var) [(var, allAnnotatedNums)]

    EBase _ bv ->
      let match eNext = case eNext.val.e__ of
        EBase _ bv' -> Just bv'
        _           -> Nothing
      in
      matchAllAndBind match eRest <| \bvs ->
        if List.all ((==) bv) bvs then return eFirst.val.e__ [] else Nothing

    EVar _ x ->
      let match eNext = case eNext.val.e__ of
        EVar _ x' -> Just x'
        _         -> Nothing
      in
      matchAllAndBind match eRest <| \xs ->
        if List.all ((==) x) xs then return eFirst.val.e__ [] else Nothing

    EFun ws1 ps eBody ws2 ->
      let match eNext = case eNext.val.e__ of
        EFun _ ps' eBody' _ -> Just (ps', eBody')
        _                   -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let (psList, eBodyList) = List.unzip stuff in
        Utils.bindMaybe2
          (\() (eBody',list) -> return (EFun ws1 ps eBody' ws2) list)
          (mergePatternLists (ps::psList))
          (mergeExpressions eBody eBodyList)

    EApp ws1 eFunc eArgs ws2 ->
      let match eNext = case eNext.val.e__ of
        EApp _ eFunc' eArgs' _ -> Just (eFunc', eArgs')
        _                      -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let (eFuncList, eArgsList) = List.unzip stuff in
        Utils.bindMaybe2
          (\(eFunc',l1) (eArgs',l2) ->
            return (EApp ws1 eFunc' eArgs' ws2) (l1 ++ l2))
          (mergeExpressions eFunc eFuncList)
          (mergeExpressionLists (eArgs::eArgsList))

    ELet ws1 letKind rec p1 e1 e2 ws2 ->
      let match eNext = case eNext.val.e__ of
        ELet _ _ _ p1' e1' e2' _ -> Just ((p1', e1'), e2')
        _                        -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let ((p1List, e1List), e2List) =
          Utils.mapFst List.unzip (List.unzip stuff)
        in
        Utils.bindMaybe3
          (\_ (e1',l1) (e2',l2) ->
            return (ELet ws1 letKind rec p1 e1' e2' ws2) (l1 ++ l2))
          (mergePatterns p1 p1List)
          (mergeExpressions e1 e1List)
          (mergeExpressions e2 e2List)

    EList ws1 es ws2 me ws3 ->
      let match eNext = case eNext.val.e__ of
        EList _ es' _ me' _ -> Just (es', me')
        _                   -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let (esList, meList) = List.unzip stuff in
        Utils.bindMaybe2
          (\(es',l1) (me',l2) -> return (EList ws1 es' ws2 me' ws3) (l1 ++ l2))
          (mergeExpressionLists (es::esList))
          (mergeMaybeExpressions me meList)

    EOp ws1 op es ws2 ->
      let match eNext = case eNext.val.e__ of
        EOp _ op' es' _ -> Just (op', es')
        _               -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let (opList, esList) = List.unzip stuff in
        if List.all ((==) op.val) (List.map .val opList) then
          Utils.bindMaybe
            (\(es',l) -> return (EOp ws1 op es' ws2) l)
            (mergeExpressionLists (es::esList))
        else
          Nothing

    EIf ws1 e1 e2 e3 ws2 ->
      let match eNext = case eNext.val.e__ of
        EIf _ e1' e2' e3' _ -> Just ((e1', e2'), e3')
        _                   -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let ((e1List, e2List), e3List) = Utils.mapFst List.unzip (List.unzip stuff) in
        Utils.bindMaybe3
          (\(e1',l1) (e2',l2) (e3',l3) ->
            return (EIf ws1 e1' e2' e3' ws2) (l1 ++ l2 ++ l3))
          (mergeExpressions e1 e1List)
          (mergeExpressions e2 e2List)
          (mergeExpressions e3 e3List)

    EComment ws s e ->
      let match eNext = case eNext.val.e__ of
        EComment _ _ e' -> Just e'
        _               -> Nothing
      in
      matchAllAndBind match eRest <| \es ->
        Utils.bindMaybe
          (\(e',l) -> return (EComment ws s e') l)
          (mergeExpressions e es)

    ETyp ws1 pat tipe e ws2 ->
      let match eNext = case eNext.val.e__ of
        ETyp _ pat tipe e _ -> Just ((pat, tipe), e)
        _                   -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let ((patList, typeList), eList) =
          Utils.mapFst List.unzip (List.unzip stuff)
        in
        Utils.bindMaybe3
          (\_ _ (e',l) ->
            return (ETyp ws1 pat tipe e' ws2) l)
          (mergePatterns pat patList)
          (mergeTypes tipe typeList)
          (mergeExpressions e eList)

    EColonType ws1 e ws2 tipe ws3 ->
      let match eNext = case eNext.val.e__ of
        EColonType _ e _ tipe _ -> Just (e,tipe)
        _                       -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let (eList, typeList) = List.unzip stuff in
        Utils.bindMaybe2
          (\(e',l) _ ->
            return (EColonType ws1 e' ws2 tipe ws3) l)
          (mergeExpressions e eList)
          (mergeTypes tipe typeList)

    ETypeAlias ws1 pat tipe e ws2 ->
      let match eNext = case eNext.val.e__ of
        ETypeAlias _ pat tipe e _ -> Just ((pat, tipe), e)
        _                         -> Nothing
      in
      matchAllAndBind match eRest <| \stuff ->
        let ((patList, typeList), eList) =
          Utils.mapFst List.unzip (List.unzip stuff)
        in
        Utils.bindMaybe3
          (\_ _ (e',l) ->
            return (ETypeAlias ws1 pat tipe e' ws2) l)
          (mergePatterns pat patList)
          (mergeTypes tipe typeList)
          (mergeExpressions e eList)

    ECase _ _ _ _ ->
      let _ = Debug.log "mergeExpressions: TODO handle: " eFirst in
      Nothing

    ETypeCase _ _ _ _ ->
      let _ = Debug.log "mergeExpressions: TODO handle: " eFirst in
      Nothing

    EOption _ _ _ _ _ ->
      let _ = Debug.log "mergeExpressions: options shouldn't appear nested: " () in
      Nothing

    EIndList _ _ _ ->
      let _ = Debug.log "mergeExpressions: TODO handle: " eFirst in
      Nothing

matchAllAndBind : (a -> Maybe b) -> List a -> (List b -> Maybe c) -> Maybe c
matchAllAndBind f xs g = Utils.bindMaybe g (Utils.projJusts (List.map f xs))

mergeExpressionLists
    : List (List Exp)
   -> Maybe (List Exp, List (Ident, List AnnotatedNum))
mergeExpressionLists lists =
  case Utils.maybeZipN lists of
    Nothing -> Nothing
    Just listListExp ->
      let foo listExp maybeAcc =
        case (listExp, maybeAcc) of
          (e::es, Just (acc1,acc2)) ->
            case mergeExpressions e es of
              Nothing     -> Nothing
              Just (e',l) -> Just (acc1 ++ [e'], acc2 ++ l)
          _ ->
            Nothing
      in
      List.foldl foo (Just ([],[])) listListExp

mergeMaybeExpressions
    : Maybe Exp -> List (Maybe Exp)
   -> Maybe (Maybe Exp, List (Ident, List AnnotatedNum))
mergeMaybeExpressions me mes =
  case me of
    Nothing ->
      if List.all ((==) Nothing) mes
        then Just (Nothing, [])
        else Nothing
    Just e  ->
      Utils.bindMaybe
        (Utils.mapMaybe (Utils.mapFst Just) << mergeExpressions e)
        (Utils.projJusts mes)

mergePatterns : Pat -> List Pat -> Maybe ()
mergePatterns pFirst pRest =
  case pFirst.val of
    PVar _ x _ ->
      let match pNext = case pNext.val of
        PVar _ x' _ -> Just x'
        _           -> Nothing
      in
      matchAllAndCheckEqual match pRest x
    PConst _ n ->
      let match pNext = case pNext.val of
        PConst _ n' -> Just n'
        _           -> Nothing
      in
      matchAllAndCheckEqual match pRest n
    PBase _ bv ->
      let match pNext = case pNext.val of
        PBase _ bv' -> Just bv'
        _           -> Nothing
      in
      matchAllAndCheckEqual match pRest bv
    PList _ ps _ mp _ ->
      let match pNext = case pNext.val of
        PList _ ps' _ mp' _ -> Just (ps', mp')
        _                   -> Nothing
      in
      matchAllAndBind match pRest <| \stuff ->
        let (psList, mpList) = List.unzip stuff in
        Utils.bindMaybe2
          (\_ () -> Just ())
          (mergePatternLists (ps::psList))
          (mergeMaybePatterns mp mpList)
    PAs _ x _ p ->
      let match pNext = case pNext.val of
        PAs _ x' _ p' -> Just (x', p')
        _             -> Nothing
      in
      matchAllAndBind match pRest <| \stuff ->
        let (indentList, pList) = List.unzip stuff in
        Utils.bindMaybe
          (\() -> if List.all ((==) x) indentList then Just () else Nothing)
          (mergePatterns p pList)

mergeTypes : Type -> List Type -> Maybe ()
mergeTypes tFirst tRest =
  if List.all (Types.equal tFirst) tRest
  then Just ()
  else Nothing

matchAllAndCheckEqual f xs x =
  let g ys = if List.all ((==) x) ys then Just () else Nothing in
  matchAllAndBind f xs g

mergePatternLists : List (List Pat) -> Maybe ()
mergePatternLists lists =
  case Utils.maybeZipN lists of
    Nothing -> Nothing
    Just listListPat ->
      let foo listPat maybeAcc =
        case (listPat, maybeAcc) of
          (p::ps, Just ()) -> mergePatterns p ps
          _                -> Nothing
      in
      List.foldl foo (Just ()) listListPat

mergeMaybePatterns : Maybe Pat -> List (Maybe Pat) -> Maybe ()
mergeMaybePatterns mp mps =
  case mp of
    Nothing -> if List.all ((==) Nothing) mps then Just () else Nothing
    Just p  -> Utils.bindMaybe (mergePatterns p) (Utils.projJusts mps)

annotatedNumToComparable : AnnotatedNum -> (Num, Frozen, Float, Float)
annotatedNumToComparable (n, frzn, wd) =
  case wd.val of
    IntSlider a _ b _ -> (n, frzn, toFloat a.val, toFloat b.val)
    NumSlider a _ b _ -> (n, frzn, a.val, b.val)
    NoWidgetDecl      -> (n, frzn, 1, -1)


--------------------------------------------------------------------------------
-- Lambda Tool

lambdaToolOptionsOf : Program -> List Exp
lambdaToolOptionsOf (defs, mainExp) =
  case mainExp of

    Blobs blobs _ ->
      let boundedFuncs =
        -- will be easier with better TopDefs
        List.concatMap (\(_,p,e,_) ->
          case (p.val, e.val.e__) of
            (PVar _ f _, EFun _ params _ _) ->
              case List.reverse params of
                lastParam :: _ ->
                  case varsOfPat lastParam of
                    ["bounds"]                   -> [f]
                    ["left","top","right","bot"] -> [f]
                    _                            -> []
                [] -> []
            _ -> []
          ) defs
      in
      let withBoundsBlobs =
        List.reverse <| -- reverse so that most recent call wins
          List.concatMap (\blob ->
            case blob of
              NiceBlob _ (WithBoundsBlob (_, f, args)) -> [(f,args)]
              _                                        -> []
            ) blobs
      in
      let lambdaCalls =
        List.concatMap (\f ->
          let pred (g,_) = f == g in
          case Utils.findFirst pred withBoundsBlobs of
            Nothing       -> []
            Just (g,args) -> [withDummyPos (EApp " " (eVar0 f) args "")]
          ) boundedFuncs
      in
      lambdaCalls

    _ -> []


--------------------------------------------------------------------------------
-- Mouse Events

onMouseClick click old =
  case (old.tool, old.mouseMode) of

    -- Inactive zone
    (Cursor, MouseObject i k z Nothing) ->
      onClickPrimaryZone i k z { old | mouseMode = MouseNothing }

    -- Active zone but not dragged
    (Cursor, MouseObject i k z (Just (_, _, False))) ->
      onClickPrimaryZone i k z { old | mouseMode = MouseNothing }

    (Poly stk, MouseDrawNew points) ->
      let pointOnCanvas = clickToCanvasPoint old click in
      let add () =
        let points' = (old.keysDown, pointOnCanvas) :: points in
        { old | mouseMode = MouseDrawNew points' }
      in
      if points == [] then add ()
      else
        let (_,initialPoint) = Utils.last_ points in
        if Utils.distanceInt pointOnCanvas initialPoint > View.drawNewPolygonDotSize then add ()
        else if List.length points == 2 then { old | mouseMode = MouseNothing }
        else if List.length points == 1 then switchToCursorTool old
        else addPolygonToCodeAndRun stk old points

    (Path stk, MouseDrawNew points) ->
      let pointOnCanvas = clickToCanvasPoint old click in
      let add new =
        let points' = (old.keysDown, new) :: points in
        (points', { old | mouseMode = MouseDrawNew points' })
      in
      case points of
        [] -> snd (add pointOnCanvas)
        (_,firstClick) :: [] ->
          if Utils.distanceInt pointOnCanvas firstClick < View.drawNewPolygonDotSize
          then switchToCursorTool old
          else snd (add pointOnCanvas)
        (_,lastClick) :: _ ->
          if Utils.distanceInt pointOnCanvas lastClick < View.drawNewPolygonDotSize
          then addPathToCodeAndRun stk old points
          else
            let (_,firstClick) = Utils.last_ points in
            if Utils.distanceInt pointOnCanvas firstClick < View.drawNewPolygonDotSize
            then
              let (points',old') = add firstClick in
              addPathToCodeAndRun stk old' points'
            else
              snd (add pointOnCanvas)

    (HelperDot, MouseDrawNew []) ->
      let pointOnCanvas = (old.keysDown, clickToCanvasPoint old click) in
      { old | mouseMode = MouseDrawNew [pointOnCanvas] }

    (_, MouseDrawNew []) -> switchToCursorTool old

    _ -> old

onClickPrimaryZone i k z old =
  let hoveredCrosshairs' =
    case LangSvg.zoneToCrosshair k z of
      Just (xFeature, yFeature) ->
        Set.insert (i, xFeature, yFeature) old.hoveredCrosshairs
      _ ->
        old.hoveredCrosshairs
  in
  let (selectedShapes', selectedBlobs') =
    let selectThisShape () =
      Set.insert i <|
        if old.keysDown == Keys.shift
        then old.selectedShapes
        else Set.empty
    in
    let selectBlob blobId =
      Dict.insert blobId i <|
        if old.keysDown == Keys.shift
        then old.selectedBlobs
        else Dict.empty
    in
    let maybeBlobId =
      case Dict.get i (snd old.slate) of
        Just (LangSvg.SvgNode _ l _) -> View.maybeFindBlobId l
        _                            -> Debug.crash "onClickPrimaryZone"
    in
    case (k, z, maybeBlobId) of
      ("line", "Edge",     Just blobId) -> (selectThisShape (), selectBlob blobId)
      (_,      "Interior", Just blobId) -> (selectThisShape (), selectBlob blobId)
      ("line", "Edge",     Nothing)     -> (selectThisShape (), old.selectedBlobs)
      (_,      "Interior", Nothing)     -> (selectThisShape (), old.selectedBlobs)
      _                                 -> (old.selectedShapes, old.selectedBlobs)
  in
  { old | hoveredCrosshairs = hoveredCrosshairs'
        , selectedShapes = selectedShapes'
        , selectedBlobs = selectedBlobs'
        }

onMouseMove (mx0, my0) old =
  let (mx, my) = clickToCanvasPoint old (mx0, my0) in
  case old.mouseMode of

    MouseNothing -> old

    MouseResizeMid Nothing ->
      let f =
        case old.orient of
          Vertical   -> \(mx1,_) -> (old.midOffsetX + mx1 - mx0, old.midOffsetY)
          Horizontal -> \(_,my1) -> (old.midOffsetY, old.midOffsetY + my1 - my0)
      in
      { old | mouseMode = MouseResizeMid (Just f) }

    MouseResizeMid (Just f) ->
      let (x,y) = f (mx0, my0) in
      { old | midOffsetX = x , midOffsetY = y }

    MouseObject id kind zone Nothing ->
      old

    MouseObject id kind zone (Just (mStuff, (mx0, my0), _)) ->
      let (dx, dy) = (mx - mx0, my - my0) in
      let (newE,newV,changes,newSlate,newWidgets) =
        applyTrigger id kind zone old mx0 my0 dx dy in
      { old | code = unparse newE
            , inputExp = newE
            , inputVal = newV
            , slate = newSlate
            , widgets = newWidgets
            , codeBoxInfo = highlightChanges mStuff changes old.codeBoxInfo
            , mouseMode =
                MouseObject id kind zone (Just (mStuff, (mx0, my0), True))
            }

    MouseSlider widget Nothing ->
      let onNewPos = createMousePosCallbackSlider mx my widget old in
      { old | mouseMode = MouseSlider widget (Just onNewPos) }

    MouseSlider widget (Just onNewPos) ->
      let (newE,newV,newSlate,newWidgets) = onNewPos (mx, my) in
      { old | code = unparse newE
            , inputExp = newE
            , inputVal = newV
            , slate = newSlate
            , widgets = newWidgets
            }

    MouseDrawNew points ->
      case (old.tool, points) of
        (Poly _, _) -> old -- handled by onMouseClick instead
        (Path _, _) -> old -- handled by onMouseClick instead
        (_, []) ->
          let pointOnCanvas = (old.keysDown, (mx, my)) in
          { old | mouseMode = MouseDrawNew [pointOnCanvas, pointOnCanvas] }
        (_, (_::points)) ->
          let pointOnCanvas = (old.keysDown, (mx, my)) in
          { old | mouseMode = MouseDrawNew (pointOnCanvas::points) }

onMouseUp old =
  case (old.mode, old.mouseMode) of

    (Print _, _) -> old
    (_, MouseObject i k z (Just _)) ->
      -- 8/10: re-parsing to get new position info after live sync-ing
      -- TODO: could update positions within highlightChanges
      -- TODO: update inputVal?
      let e = Utils.fromOk_ <| parseE old.code in
      let old' = { old | inputExp = e } in
      refreshHighlights i z
        { old' | mouseMode = MouseNothing, mode = refreshMode_ old'
               , history = addToHistory old.code old'.history }

    (_, MouseSlider _ (Just _)) ->
      let e = Utils.fromOk_ <| parseE old.code in
      let old' = { old | inputExp = e } in
        { old' | mouseMode = MouseNothing, mode = refreshMode_ old'
               , history = addToHistory old.code old'.history }

    (_, MouseDrawNew points) ->
      case (old.tool, points, old.keysDown == Keys.shift) of

        (Line _,     [pt2, pt1], _) -> addLineToCodeAndRun old pt2 pt1
        (HelperLine, [pt2, pt1], _) -> addLineToCodeAndRun old pt2 pt1

        (Rect Raw,      [pt2, pt1], False) -> addRawRect old pt2 pt1
        (Rect Raw,      [pt2, pt1], True)  -> addRawSquare old pt2 pt1
        (Rect Stretchy, [pt2, pt1], False) -> addStretchyRect old pt2 pt1
        (Rect Stretchy, [pt2, pt1], True)  -> addStretchySquare old pt2 pt1

        (Oval Raw,      [pt2, pt1], False) -> addRawOval old pt2 pt1
        (Oval Raw,      [pt2, pt1], True)  -> addRawCircle old pt2 pt1
        (Oval Stretchy, [pt2, pt1], False) -> addStretchyOval old pt2 pt1
        (Oval Stretchy, [pt2, pt1], True)  -> addStretchyCircle old pt2 pt1

        (HelperDot, [pt], _) -> addHelperDotToCodeAndRun old pt

        (Lambda, [pt2, pt1], _) -> addLambdaToCodeAndRun old pt2 pt1

        (Poly _, _, _) -> old
        (Path _, _, _) -> old

        (_, [], _)     -> switchToCursorTool old

        _              -> old

    _ -> { old | mouseMode = MouseNothing, mode = refreshMode_ old }


--------------------------------------------------------------------------------
-- Updating the Model

upstate : Event -> Model -> Model
upstate evt old = case debugLog "Event" evt of

    Noop -> old

    WindowDimensions wh -> { old | dimensions = wh }

    Run ->
      case parseE old.code of
        Ok e ->
         let (newVal,ws) = (Eval.run e) in
         let (newSlideCount, newMovieCount, newMovieDuration, newMovieContinue, newSlate) = LangSvg.fetchEverything old.slideNumber old.movieNumber 0.0 newVal in
         let newCode = unparse e in
         let lambdaTools' =
           -- TODO should put program into Model
           let program = splitExp e in
           let options = lambdaToolOptionsOf program ++ snd sampleModel.lambdaTools in
           let selectedIdx = min (fst old.lambdaTools) (List.length options) in
           (selectedIdx, options)
         in
         let _ = Types.typecheck e in
         let new =
           { old | inputExp      = e
                 , inputVal      = newVal
                 , code          = newCode
                 , slideCount    = newSlideCount
                 , movieCount    = newMovieCount
                 , movieTime     = 0
                 , movieDuration = newMovieDuration
                 , movieContinue = newMovieContinue
                 , runAnimation  = newMovieDuration > 0
                 , slate         = newSlate
                 , widgets       = ws
                 , history       = addToHistory newCode old.history
                 , caption       = Nothing
                 , syncOptions   = Sync.syncOptionsOf old.syncOptions e
                 , lambdaTools   = lambdaTools'
           }
         in
          { new | mode = refreshMode_ new
                , errorBox = Nothing }
        Err err ->
          { old | caption = Just (LangError ("PARSE ERROR!\n" ++ err)) }

    StartAnimation -> upstate Redraw { old | movieTime = 0
                                           , runAnimation = True }

    Redraw ->
      case old.inputVal of
        val ->
          let (newSlideCount, newMovieCount, newMovieDuration, newMovieContinue, newSlate) = LangSvg.fetchEverything old.slideNumber old.movieNumber old.movieTime val in
          { old | slideCount    = newSlideCount
                , movieCount    = newMovieCount
                , movieDuration = newMovieDuration
                , movieContinue = newMovieContinue
                , slate         = newSlate }

    ToggleOutput ->
      let m = case old.mode of
        Print _ -> refreshMode_ old
        _       -> Print (LangSvg.printSvg old.showGhosts old.slate)
      in
      { old | mode = m }

    StartResizingMid ->
      if old.hideCode then old
      else if old.hideCanvas then old
      else { old | mouseMode = MouseResizeMid Nothing }

    SelectObject id kind zone ->
      let mStuff = maybeStuff id kind zone old in
      case mStuff of

        Nothing -> -- Inactive zone
          { old | mouseMode = MouseObject id kind zone Nothing }

        Just _  -> -- Active zone
          let (mx, my) = clickToCanvasPoint old (snd old.mouseState) in
          let blah = Just (mStuff, (mx, my), False) in
          { old | mouseMode = MouseObject id kind zone blah }

    MouseClickCanvas ->
      case (old.tool, old.mouseMode) of
        (Cursor, MouseObject _ _ _ _) -> old
        (Cursor, _) ->
          { old | selectedShapes = Set.empty, selectedBlobs = Dict.empty }

        (_ , MouseNothing) ->
          { old | mouseMode = MouseDrawNew []
                , selectedShapes = Set.empty, selectedBlobs = Dict.empty }

        _ -> old

    MousePosition pos' ->
      case old.mouseState of
        (Nothing, _)    -> { old | mouseState = (Nothing, pos') }
        (Just False, _) -> onMouseMove pos' { old | mouseState = (Just True, pos') }
        (Just True, _)  -> onMouseMove pos' { old | mouseState = (Just True, pos') }

    MouseIsDown b ->
      let old =
        let (x,y) = snd old.mouseState in
        let lightestColor = 470 in
        { old | randomColor = (old.randomColor + x + y) % lightestColor }
      in
      case (b, old.mouseState) of

        (True, (Nothing, pos)) -> -- mouse down
          let _ = debugLog "mouse down" () in
          { old | mouseState = (Just False, pos) }

        (False, (Just False, pos)) -> -- click (mouse up after not being dragged)
          let _ = debugLog "mouse click" () in
          onMouseClick pos { old | mouseState = (Nothing, pos) }

        (False, (Just True, pos)) -> -- mouse up (after being dragged)
          let _ = debugLog "mouse up" () in
          onMouseUp { old | mouseState = (Nothing, pos) }

        (False, (Nothing, _)) ->
          let _ = debugLog "mouse down was preempted by a handler in View" () in
          old

        -- (True, (Just _, _)) -> Debug.crash "upstate MouseIsDown: impossible"
        (True, (Just _, _)) ->
          let _ = Debug.log "upstate MouseIsDown: impossible" () in
          old

    TickDelta deltaT ->
      case old.mode of
        SyncSelect _ ->
          -- Prevent "jump" after slow first frame render.
          let adjustedDeltaT = if old.syncSelectTime == 0.0 then clamp 0.0 50 deltaT else deltaT in
          upstate Redraw { old | syncSelectTime = old.syncSelectTime + (adjustedDeltaT / 1000) }
        _ ->
          if old.movieTime < old.movieDuration then
            -- Prevent "jump" after slow first frame render.
            let adjustedDeltaT = if old.movieTime == 0.0 then clamp 0.0 50 deltaT else deltaT in
            let newMovieTime = clamp 0.0 old.movieDuration (old.movieTime + (adjustedDeltaT / 1000)) in
            upstate Redraw { old | movieTime = newMovieTime }
          else if old.movieContinue == True then
            upstate NextMovie old
          else
            { old | runAnimation = False }


    RelateAttrs ->
      let selectedVals =
        let locIdToNumberAndLoc = ValueBasedTransform.locIdToNumberAndLocOf old.inputExp in
        debugLog "selectedVals" <|
          ValueBasedTransform.pluckSelectedVals old.selectedFeatures old.slate locIdToNumberAndLoc
      in
      let revert = (old.inputExp, old.inputVal) in
      let (nextK, l) = Sync.relate old.genSymCount old.inputExp selectedVals in
      let possibleChanges = List.map (addSlateAndCode old) l in
        { old | mode = SyncSelect possibleChanges
              , genSymCount = nextK
              , selectedFeatures = Set.empty -- TODO
              , runAnimation = True
              , syncSelectTime = 0.0
              }

    DigHole ->
      let newExp =
        ValueBasedTransform.digHole old.inputExp old.selectedFeatures old.slate old.syncOptions
      in
      let (newVal, newWidgets) = Eval.run newExp in
      let (newSlate, newCode)  = slateAndCode old (newExp, newVal) in
      debugLog "new model" <|
        { old | code             = newCode
              , inputExp         = newExp
              , inputVal         = newVal
              , history          = addToHistory old.code old.history
              , slate            = newSlate
              , widgets          = newWidgets
              , previewCode      = Nothing
              , mode             = mkLive old.syncOptions old.slideNumber old.movieNumber old.movieTime newExp newVal
              , selectedFeatures = Set.empty
        }

    MakeEqual ->
      let newExp =
        ValueBasedTransform.makeEqual
            old.inputExp
            old.selectedFeatures
            old.slideNumber
            old.movieNumber
            old.movieTime
            old.syncOptions
      in
      let (newVal, newWidgets) = Eval.run newExp in
      let (newSlate, newCode)  = slateAndCode old (newExp, newVal) in
      upstate CleanCode <|
      debugLog "new model" <|
        { old | code             = newCode
              , inputExp         = newExp
              , inputVal         = newVal
              , history          = addToHistory old.code old.history
              , slate            = newSlate
              , widgets          = newWidgets
              , previewCode      = Nothing
              , mode             = mkLive old.syncOptions old.slideNumber old.movieNumber old.movieTime newExp newVal
              , selectedFeatures = Set.empty
        }

    MakeEquidistant ->
      let newExp =
        ValueBasedTransform.makeEquidistant
            old.inputExp
            old.selectedFeatures
            old.slideNumber
            old.movieNumber
            old.movieTime
            old.slate
            old.syncOptions
      in
      let (newVal, newWidgets) = Eval.run newExp in
      let (newSlate, newCode)  = slateAndCode old (newExp, newVal) in
      debugLog "new model" <|
        { old | code             = newCode
              , inputExp         = newExp
              , inputVal         = newVal
              , history          = addToHistory old.code old.history
              , slate            = newSlate
              , widgets          = newWidgets
              , previewCode      = Nothing
              , mode             = mkLive old.syncOptions old.slideNumber old.movieNumber old.movieTime newExp newVal
              , selectedFeatures = Set.empty
        }

    GroupBlobs ->
      if Dict.size old.selectedBlobs <= 1 then old
      else
        let (defs,me) = splitExp old.inputExp in
        case me of
          Blobs blobs f -> groupSelectedBlobs old defs blobs f
          _             -> old

    DuplicateBlobs ->
      duplicateSelectedBlobs old

    MergeBlobs ->
      if Dict.size old.selectedBlobs <= 1 then old
      else mergeSelectedBlobs old

    AbstractBlobs ->
      abstractSelectedBlobs old

{-
    RelateShapes ->
      let newval = slateToVal old.slate in
      let l = Sync.inferNewRelationships old.inputExp old.inputVal newval in
      let possibleChanges = List.map (addSlateAndCode old) l in
        { old | mode = SyncSelect possibleChanges, runAnimation = True, syncSelectTime = 0.0 }
-}

    -- TODO AdHoc/Sync not used at the moment
    Sync ->
      case (old.mode, old.inputExp) of
        (AdHoc, ip) ->
          let
            -- If stuff breaks, try re-adding this.
            -- We forgot why it was here.
            -- inputval   = fst <| Eval.run ip
            -- inputSlate = LangSvg.resolveToIndexedTree old.slideNumber old.movieNumber old.movieTime inputval
            -- inputval'  = slateToVal inputSlate
            newval     = slateToVal old.slate
            local      = Sync.inferLocalUpdates old.syncOptions ip old.inputVal newval
            struct     = Sync.inferStructuralUpdates ip old.inputVal newval
            delete     = Sync.inferDeleteUpdates ip old.inputVal newval
            relatedG   = Sync.inferNewRelationships ip old.inputVal newval
            relatedV   = Sync.relateSelectedAttrs old.genSymCount ip old.inputVal newval
          in
          let addSlateAndCodeToAll list = List.map (addSlateAndCode old) list in
            case (local, relatedV) of
              (Ok [], (_, [])) -> { old | mode = mkLive_ old.syncOptions old.slideNumber old.movieNumber old.movieTime ip }
              (Ok [], (nextK, changes)) ->
                let _ = debugLog ("no live updates, only related var") () in
                let m = SyncSelect (addSlateAndCodeToAll changes) in
                { old | mode = m, genSymCount = nextK, runAnimation = True, syncSelectTime = 0.0 }
              (Ok live, _) ->
                let n = debugLog "# of live updates" (List.length live) in
                let changes = live ++ delete ++ relatedG ++ struct in
                let m = SyncSelect (addSlateAndCodeToAll changes) in
                { old | mode = m, runAnimation = True, syncSelectTime = 0.0 }
              (Err e, _) ->
                let _ = debugLog ("no live updates: " ++ e) () in
                let changes = delete ++ relatedG ++ struct in
                let m = SyncSelect (addSlateAndCodeToAll changes) in
                { old | mode = m, runAnimation = True, syncSelectTime = 0.0 }
        _ -> Debug.crash "upstate Sync"

    SelectOption (exp, val, slate, code) ->
        { old | code          = code
              , inputExp      = exp
              , inputVal      = val
              , history       = addToHistory old.code old.history
              , slate         = slate
              , previewCode   = Nothing
              , tool          = Cursor
              , mode          = mkLive old.syncOptions old.slideNumber old.movieNumber old.movieTime exp val }


    PreviewCode maybeCode ->
      { old | previewCode = maybeCode }

    CancelSync ->
      upstate Run { old | mode = mkLive_ old.syncOptions old.slideNumber old.movieNumber old.movieTime old.inputExp }

    SelectExample name thunk ->
      if name == Examples.scratchName then
        upstate Run { old | exName = name, code = old.scratchCode, history = ([],[]) }
      else

      let {e,v,ws} = thunk () in
      let (so, m) =
        case old.mode of
          Live _  -> let so = Sync.syncOptionsOf old.syncOptions e in (so, mkLive so old.slideNumber old.movieNumber old.movieTime e v)
          Print _ -> let so = Sync.syncOptionsOf old.syncOptions e in (so, mkLive so old.slideNumber old.movieNumber old.movieTime e v)
          _      -> (old.syncOptions, old.mode)
      in
      let scratchCode' =
        if old.exName == Examples.scratchName then old.code else old.scratchCode
      in
      let (slideCount, movieCount, movieDuration, movieContinue, slate) = LangSvg.fetchEverything old.slideNumber old.movieNumber old.movieTime v in
      let code = unparse e in
      { old | scratchCode   = scratchCode'
            , exName        = name
            , inputExp      = e
            , inputVal      = v
            , code          = code
            , history       = ([code],[])
            , mode          = m
            , syncOptions   = so
            , slideNumber   = 1
            , slideCount    = slideCount
            , movieCount    = movieCount
            , movieTime     = 0
            , movieDuration = movieDuration
            , movieContinue = movieContinue
            , runAnimation  = movieDuration > 0
            , slate         = slate
            , widgets       = ws
            }

    SwitchMode m -> { old | mode = m }

    SwitchOrient -> { old | orient = switchOrient old.orient }

    Undo ->
      case old.history of
        ([],_)         -> old
        ([firstRun],_) -> old
        (lastRun::secondToLast::older, future) ->
          let new = { old | history = (secondToLast::older, lastRun::future)
                          , code    = secondToLast } in
          upstate Run new

    Redo ->
      case old.history of
        (_,[]) -> old
        (past, next::future) ->
          let new = { old | history = (next::past, future)
                          , code    = next } in
          upstate Run new

    NextSlide ->
      if old.slideNumber >= old.slideCount then
        upstate StartAnimation { old | slideNumber = old.slideNumber
                                     , movieNumber = old.movieCount }
      else
        upstate StartAnimation { old | slideNumber = old.slideNumber + 1
                                     , movieNumber = 1 }

    PreviousSlide ->
      if old.slideNumber <= 1 then
        upstate StartAnimation { old | slideNumber = 1
                                     , movieNumber = 1 }
      else
        let previousSlideNumber    = old.slideNumber - 1 in
        case old.inputExp of
          exp ->
            let previousVal = fst <| Eval.run exp in
            let previousMovieCount = LangSvg.resolveToMovieCount previousSlideNumber previousVal in
            upstate StartAnimation { old | slideNumber = previousSlideNumber
                                         , movieNumber = previousMovieCount }

    NextMovie ->
      if old.movieNumber == old.movieCount && old.slideNumber < old.slideCount then
        upstate NextSlide old
      else if old.movieNumber < old.movieCount then
        upstate StartAnimation { old | movieNumber = old.movieNumber + 1 }
      else
        -- Last movie of slide show; skip to its end.
        upstate Redraw { old | movieTime    = old.movieDuration
                             , runAnimation = False }

    PreviousMovie ->
      if old.movieNumber == 1 then
        upstate PreviousSlide old
      else
        upstate StartAnimation { old | movieNumber = old.movieNumber - 1 }

    KeysDown l ->
      let _ = debugLog "keys" (toString l) in
      let new = { old | keysDown = l } in

      if l == Keys.escape then
        case (new.tool, new.mouseMode) of
          (Cursor, _) ->
            { new | selectedFeatures = Set.empty
                  , selectedShapes = Set.empty
                  , selectedBlobs = Dict.empty
                  }
          (_, MouseNothing)   -> { new | tool = Cursor }
          (_, MouseDrawNew _) -> { new | mouseMode = MouseNothing }
          _                   -> new

      else if l == Keys.delete then
         deleteSelectedBlobs new
      -- else if l == Keys.backspace || l == Keys.delete then
      --   deleteSelectedBlobs new
      -- TODO
      -- else if l == Keys.metaPlus Keys.d then
      -- else if l == Keys.metaPlus Keys.d || l == Keys.commandPlus Keys.d then
      -- else if l == Keys.d then
      --   duplicateSelectedBlobs new
      else
        new

{-      case old.mode of
          SaveDialog _ -> old
          _ -> case editingMode old of
            True -> if
              | l == keysMetaShift -> upstate Run old
              | otherwise -> old
            False -> if
              | l == keysE -> upstate Edit old
              | l == keysZ -> upstate Undo old
              -- | l == keysShiftZ -> upstate Redo old
              | l == keysY -> upstate Redo old
              | l == keysG || l == keysH -> -- for right- or left-handers
                  upstate ToggleZones old
              | l == keysO -> upstate ToggleOutput old
              | l == keysP -> upstate SwitchOrient old
              | l == keysS ->
                  let _ = Debug.log "TODO Save" () in
                  upstate Noop old
              | l == keysShiftS ->
                  let _ = Debug.log "TODO Save As" () in
                  upstate Noop old
              | l == keysRight -> adjustMidOffsetX old 25
              | l == keysLeft  -> adjustMidOffsetX old (-25)
              | l == keysUp    -> adjustMidOffsetY old (-25)
              | l == keysDown  -> adjustMidOffsetY old 25
              | otherwise -> old
-}

{-
      let fire evt = upstate evt old in

      case editingMode old of

        True ->
          if l == keysEscShift then fire Run
          else                      fire Noop

        False ->

          -- events for any non-editing mode
          if      l == keysO          then fire ToggleOutput
          else if l == keysP          then fire SwitchOrient
          else if l == keysShiftRight then adjustMidOffsetX old 25
          else if l == keysShiftLeft  then adjustMidOffsetX old (-25)
          else if l == keysShiftUp    then adjustMidOffsetY old (-25)
          else if l == keysShiftDown  then adjustMidOffsetY old 25

          -- events for specific non-editing mode
          else case old.mode of

              Live _ ->
                if      l == keysE        then fire Edit
                else if l == keysZ        then fire Undo
                else if l == keysY        then fire Redo
                else if l == keysT        then fire (SwitchMode AdHoc)
                else if l == keysS        then fire Noop -- placeholder for Save
                else if l == keysShiftS   then fire Noop -- placeholder for Save As
                else                           fire Noop

              AdHoc ->
                if      l == keysZ        then fire Undo
                else if l == keysY        then fire Redo
                else if l == keysT        then fire Sync
                else                           fire Noop

              _                       -> fire Noop
-}

    CleanCode ->
      case parseE old.code of
        Err err ->
          { old | caption = Just (LangError ("PARSE ERROR!\n" ++ err)) }
        Ok reparsed ->
          let cleanedExp =
            reparsed
            |> cleanExp
            |> LangTransform.simplify
            |> LangTransform.removeExtraPostfixes ["_orig", "'"]
            |> freshen
          in
          let code' = unparse cleanedExp in
          let history' =
            if old.code == code'
              then old.history
              else addToHistory code' old.history
          in
          let _ = debugLog "Cleaned: " code' in
          let newModel = { old | inputExp = cleanedExp, code = code', history = history' } in
          newModel

    -- Elm does not have function equivalence/pattern matching, so we need to
    -- thread these events through upstate in order to catch them to rerender
    -- appropriately (see CodeBox.elm)
    InstallSaveState -> installSaveState old
    RemoveDialog makeSave saveName -> removeDialog makeSave saveName old
    ToggleBasicCodeBox -> { old | basicCodeBox = not old.basicCodeBox }
    UpdateFieldContents fieldContents -> { old | fieldContents = fieldContents }

    UpdateModel f -> f old

    -- Lets multiple events be executed in sequence (useful for CodeBox.elm)
    MultiEvent evts -> case evts of
      [] -> old
      e1 :: es -> upstate e1 old |> upstate (MultiEvent es)

    WaitRun -> old
    WaitSave saveName -> { old | exName = saveName }
    WaitClean -> old
    WaitCodeBox -> old

adjustMidOffsetX old dx =
  case old.orient of
    Vertical   -> { old | midOffsetX = old.midOffsetX + dx }
    Horizontal -> upstate SwitchOrient old

adjustMidOffsetY old dy =
  case old.orient of
    Horizontal -> { old | midOffsetY = old.midOffsetY + dy }
    Vertical   -> upstate SwitchOrient old



--------------------------------------------------------------------------------
-- Mouse Callbacks for Zones

applyTrigger objid kind zone old mx0 my0 dx_ dy_ =
  let dx = if old.keysDown == Keys.y then 0 else dx_ in
  let dy = if old.keysDown == Keys.x then 0 else dy_ in
  case old.mode of
    AdHoc ->
      (old.inputExp, old.inputVal, Dict.empty, old.slate, old.widgets)
    Live info ->
      case Utils.justGet_ "#4" zone (Utils.justGet_ "#5" objid info.triggers) of
        Nothing -> Debug.crash "shouldn't happen due to upstate SelectObject"
        Just trigger ->
          let (newE,changes) = trigger (mx0, my0) (dx, dy) in
          let (newVal,newWidgets) = Eval.run newE in
          (newE, newVal, changes, LangSvg.valToIndexedTree newVal, newWidgets)
    _ -> Debug.crash "applyTrigger"


--------------------------------------------------------------------------------
-- Mouse Callbacks for UI Widgets

wSlider = params.mainSection.uiWidgets.wSlider

createMousePosCallbackSlider mx my widget old =

  let (maybeRound, minVal, maxVal, curVal, locid) =
    case widget of
      WIntSlider a b _ curVal (locid,_,_) ->
        (toFloat << round, toFloat a, toFloat b, toFloat curVal, locid)
      WNumSlider a b _ curVal (locid,_,_) ->
        (identity, a, b, curVal, locid)
  in
  let range = maxVal - minVal in

  \(mx',my') ->
    let newVal =
      curVal + (toFloat (mx' - mx) / toFloat wSlider) * range
        |> clamp minVal maxVal
        |> maybeRound
    in
    -- unlike the live triggers via Sync,
    -- this substitution only binds the location to change
    let subst = Dict.singleton locid newVal in
    let newE = applyLocSubst subst old.inputExp in
    let (newVal,newWidgets) = Eval.run newE in
    -- Can't manipulate slideCount/movieCount/movieDuration/movieContinue via sliders at the moment.
    let newSlate = LangSvg.resolveToIndexedTree old.slideNumber old.movieNumber old.movieTime newVal in
    (newE, newVal, newSlate, newWidgets)