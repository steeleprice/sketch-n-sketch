module ShapeWidgets exposing (..)

import Lang exposing (..)
import FastParser
import LangUnparser
import LangSvg exposing (RootedIndexedTree, IndexedTree, NodeId, ShapeKind, Attr, AVal)
-- import LangTools --temporary
import Provenance
import Utils

import Dict
import Regex
import Set exposing (Set)
import String


------------------------------------------------------------------------------
-- Shape Features

type Feature
  = PointFeature PointFeature
  | DistanceFeature DistanceFeature
  | OtherFeature OtherFeature

type PointFeature
  = TopLeft | TopRight  | BotLeft | BotRight
  | TopEdge | RightEdge | BotEdge | LeftEdge
  | Center
  | LonePoint
  | Point Int
  | Midpoint Int
  | EndPoint

type DistanceFeature
  = Width | Height
  | Radius
  | RadiusX | RadiusY
  | Offset

type OtherFeature
  = FillColor | FillOpacity
  | StrokeColor | StrokeOpacity | StrokeWidth
  | Rotation
  | Quantity

eightPointFeatures =
  List.map PointFeature
     [ TopLeft , TopRight  , BotLeft , BotRight
     , TopEdge , RightEdge , BotEdge , LeftEdge
     ]

ninePointFeatures =
  eightPointFeatures ++ [PointFeature Center]

simpleKindFeatures : List (ShapeKind, List Feature)
simpleKindFeatures =
  [ ( "rect", ninePointFeatures ++ List.map DistanceFeature [Width, Height])
  , ( "BOX", ninePointFeatures ++ List.map DistanceFeature [Width, Height])
  , ( "circle", ninePointFeatures ++ List.map DistanceFeature [Radius])
  , ( "OVAL", ninePointFeatures ++ List.map DistanceFeature [RadiusX, RadiusY])
  , ( "ellipse", ninePointFeatures ++ List.map DistanceFeature [RadiusX, RadiusY])
  , ( "line", List.map PointFeature [Point 1, Point 2, Center])
  ]

polyKindFeatures : ShapeKind -> List Attr -> List Feature
polyKindFeatures kind attrs =
  let cap = "polyKindFeatures" in
  let err s = Debug.crash <| Utils.spaces [cap, kind, ": ", s] in
  if kind == "polygon" then
    case (Utils.find cap attrs "points").interpreted of
      LangSvg.APoints pts ->
        List.concatMap
          (\i -> [PointFeature (Point i), PointFeature (Midpoint i)])
          (List.range 1 (List.length pts))
      _ ->
        err "polyKindFeatures: points not found"
  else if kind == "path" then
    case (Utils.find cap attrs "d").interpreted of
      LangSvg.APath2 (_, pathCounts) ->
        List.concatMap
          (\i -> [PointFeature (Point i)])
          (List.range 1 (pathCounts.numPoints))
      _ ->
        err "polyKindFeatures: d not found"
  else
    err <| "polyKindFeatures: " ++ kind

featuresOfShape : ShapeKind -> List Attr -> List Feature
featuresOfShape kind attrs =
  case (Utils.maybeFind kind simpleKindFeatures, kind) of
    (Just features, _)   -> features
    (Nothing, "polygon") -> polyKindFeatures kind attrs
    (Nothing, "path")    -> polyKindFeatures kind attrs
    _                    -> []

pointFeaturesOfShape : ShapeKind -> List Attr -> List PointFeature
pointFeaturesOfShape kind attrs =
  featuresOfShape kind attrs |> List.concatMap (\feature ->
    case feature of
      PointFeature pf -> [pf]
      _               -> []
  )


------------------------------------------------------------------------------
-- FeatureNum (for selecting/relating individual values)

type FeatureNum
  = XFeat PointFeature
  | YFeat PointFeature
  | DFeat DistanceFeature
  | OFeat OtherFeature


featureNumsOfFeature : Feature -> List FeatureNum
featureNumsOfFeature feature =
  case feature of
    PointFeature pf    -> [XFeat pf, YFeat pf]
    DistanceFeature df -> [DFeat df]
    OtherFeature feat  -> [OFeat feat]


featureNumDesc : FeatureNum -> String
featureNumDesc featureNum =
  toString featureNum
  |> Utils.stringReplace " " ""
  |> Utils.stringReplace "(" ""
  |> Utils.stringReplace ")" ""


------------------------------------------------------------------------------

type alias ShapeFeature = (ShapeKind, FeatureNum)


shapeFeatureDesc : ShapeFeature -> String
shapeFeatureDesc (shapeKind, featureNum) =
  shapeKind ++ featureNumDesc featureNum


parseFeatureNum : ShapeFeature -> FeatureNum
parseFeatureNum (_, featureNum) =
  featureNum


shapeFeatureIsX : ShapeFeature -> Bool
shapeFeatureIsX (_, featureNum) =
  case featureNum of
    XFeat _ -> True
    _       -> False


shapeFeatureIsY : ShapeFeature -> Bool
shapeFeatureIsY (_, featureNum) =
  case featureNum of
    YFeat _ -> True
    _       -> False


shapeFeatureIsXOrY : ShapeFeature -> Bool
shapeFeatureIsXOrY shapeFeature =
  shapeFeatureIsX shapeFeature || shapeFeatureIsY shapeFeature


selectedShapeFeatureIsX : SelectedShapeFeature -> Bool
selectedShapeFeatureIsX (_, shapeFeature) =
  shapeFeatureIsX shapeFeature


shapeFeaturesAreXYPairs : ShapeFeature -> ShapeFeature -> Bool
shapeFeaturesAreXYPairs (shapeKind1, featureNum1) (shapeKind2, featureNum2) =
  shapeKind1 == shapeKind2 &&
  case (featureNum1, featureNum2) of
    (XFeat pointFeature1, YFeat pointFeature2) -> pointFeature1 == pointFeature2
    (YFeat pointFeature1, XFeat pointFeature2) -> pointFeature1 == pointFeature2
    _                                          -> False


selectedShapeFeaturesAreXYPairs : SelectedShapeFeature -> SelectedShapeFeature -> Bool
selectedShapeFeaturesAreXYPairs (nodeId1, shapeFeature1) (nodeId2, shapeFeature2) =
  nodeId1 == nodeId2 &&
  shapeFeaturesAreXYPairs shapeFeature1 shapeFeature2


------------------------------------------------------------------------------
-- Selected Shape Features

type alias SelectedShapeFeature = (NodeId, ShapeFeature)

selectedPointFeatureOf : SelectedShapeFeature -> SelectedShapeFeature
                      -> Maybe (NodeId, PointFeature)
selectedPointFeatureOf selected1 selected2 =
  let (id1, feature1) = selected1 in
  let (id2, feature2) = selected2 in
  if id1 /= id2 then Nothing
  else
    case pointFeatureOf feature1 feature2 of
      Just pt -> Just (id1, pt)
      Nothing -> selectedPointFeatureOf selected2 selected1 -- Ah, I think this will infinite loop.

pointFeatureOf : ShapeFeature -> ShapeFeature -> Maybe PointFeature
pointFeatureOf feature1 feature2 =
  case (parseFeatureNum feature1, parseFeatureNum feature2) of
    (XFeat pointFeature1, YFeat pointFeature2) ->
      if pointFeature1 == pointFeature2
      then Just pointFeature1
      else Nothing
    _ ->
      Nothing


------------------------------------------------------------------------------
-- Feature Equations

-- Can't just use Trace because we need to introduce
-- constants not found in the program's Subst
-- If need more structured values in the future,
-- add EqnVal AVal (rather than EqnVal Val).
--
type alias FeatureEquation    = FeatureEquationOf NumTr
type alias FeatureValEquation = FeatureEquationOf Val

type FeatureEquationOf a
  = EqnNum a
  | EqnOp Op_ (List (FeatureEquationOf a))


selectedShapeFeatureToEquation : SelectedShapeFeature -> IndexedTree -> Widgets -> Dict.Dict LocId (Num, Loc) -> Maybe FeatureEquation
selectedShapeFeatureToEquation selectedShapeFeature tree widgets locIdToNumberAndLoc =
  selectedShapeFeatureToEquation_ featureEquation widgetFeatureEquation selectedShapeFeature tree widgets locIdToNumberAndLoc

selectedShapeFeatureToValEquation : SelectedShapeFeature -> IndexedTree -> Widgets -> Dict.Dict LocId (Num, Loc) -> Maybe FeatureValEquation
selectedShapeFeatureToValEquation selectedShapeFeature tree widgets locIdToNumberAndLoc =
  selectedShapeFeatureToEquation_ featureValEquation widgetFeatureValEquation selectedShapeFeature tree widgets locIdToNumberAndLoc

selectedShapeToValEquation : NodeId -> IndexedTree -> Maybe FeatureValEquation
selectedShapeToValEquation nodeId shapeTree =
  Dict.get nodeId shapeTree
  |> Maybe.map (\shape -> EqnNum shape.val)


selectedShapeFeatureToEquation_
  :  (ShapeFeature -> List Attr -> FeatureEquationOf a)
  -> (ShapeFeature -> Widget -> Dict.Dict LocId (Num, Loc) -> FeatureEquationOf a)
  -> SelectedShapeFeature
  -> IndexedTree
  -> Widgets
  -> Dict.Dict LocId (Num, Loc)
  -> Maybe (FeatureEquationOf a)
selectedShapeFeatureToEquation_ getFeatureEquation getWidgetFeatureEquation (nodeId, shapeFeature) tree widgets locIdToNumberAndLoc =
  if not <| nodeId < -2 then
    -- shape feature
    case Dict.get nodeId tree |> Maybe.map .interpreted of
      Just (LangSvg.SvgNode kind nodeAttrs _) ->
        Just (getFeatureEquation shapeFeature nodeAttrs)

      Just (LangSvg.TextNode _) ->
        Nothing

      Nothing ->
        Debug.crash <| "ShapeWidgets.selectedShapeFeatureToEquation " ++ (toString nodeId) ++ " " ++ (toString tree)
  else
    -- widget feature
    -- change to index widgets by position in widget list; then pull feature from widget type
    let widgetId = -nodeId - 2 in -- widget nodeId's are encoded at -2 and count down. (And they are 1-indexed, so actually they start at -3)
    case Utils.maybeGeti1 widgetId widgets of
      Just widget -> Just (getWidgetFeatureEquation shapeFeature widget locIdToNumberAndLoc)
      Nothing     -> Debug.crash <| "ShapeWidgets.selectedShapeFeatureToEquation can't find widget " ++ (toString widgetId) ++ " " ++ (toString widgets)


equationNumTrs featureEqn =
  case featureEqn of
    EqnNum val   -> [val]
    EqnOp _ eqns -> List.concatMap equationNumTrs eqns



type alias BoxyFeatureEquationsOf a =
  { left : FeatureEquationOf a
  , top : FeatureEquationOf a
  , right : FeatureEquationOf a
  , bottom : FeatureEquationOf a
  , cx : FeatureEquationOf a
  , cy : FeatureEquationOf a
  , mWidth : Maybe (FeatureEquationOf a)
  , mHeight : Maybe (FeatureEquationOf a)
  , mRadius : Maybe (FeatureEquationOf a)
  , mRadiusX : Maybe (FeatureEquationOf a)
  , mRadiusY : Maybe (FeatureEquationOf a)
  }


twoNumTr  = EqnNum (2, dummyTrace)
twoVal    = EqnNum (Val (VConst Nothing (2, dummyTrace)) (Provenance [] (eConst0 2 dummyLoc) []) (Parents []))
plus a b  = EqnOp Plus [a, b]
minus a b = EqnOp Minus [a, b]
div a b   = EqnOp Div [a, b]


featureEquation : ShapeFeature -> List Attr -> FeatureEquation
featureEquation (kind, featureNum) nodeAttrs =
  let toOpacity attr =
    case attr.interpreted of
      LangSvg.AColorNum (_, Just opacity) -> opacity
      _                                   -> Debug.crash "featureEquation: toOpacity"
  in
  featureEquationOf
      LangSvg.findNumishAttr
      LangSvg.getPathPoint
      LangSvg.getPolyPoint
      toOpacity
      LangSvg.toTransformRot
      twoNumTr
      kind
      nodeAttrs
      featureNum

featureValEquation : ShapeFeature -> List Attr -> FeatureValEquation
featureValEquation (kind, featureNum) nodeAttrs =
  let getAttr attrName attrList =
    (Utils.find ("featureValEquation: getAttr " ++ attrName) attrList attrName).val
  in
  let getPathPoint attrList i =
    let toPointValPairs vListElems =
      let commandIsAnyOf cmd options = String.contains (String.toUpper cmd) options in
      case vListElems of
        []     -> []
        v::rest -> case v.v_ of
          VBase (VString cmd) ->
            if commandIsAnyOf cmd "Z" then
              toPointValPairs rest
            else if commandIsAnyOf cmd "MLT" then
              case Utils.split 2 rest of
                ([xVal, yVal], rest) -> (xVal, yVal) :: toPointValPairs rest
                _                    -> let _ = Utils.log "toPointValPairs MLT parse fail" in []
            else if commandIsAnyOf cmd "HV" then
              toPointValPairs (List.drop 1 rest)
            else if commandIsAnyOf cmd "C" then
              case Utils.split 6 rest of
                ([x1,y1,x2,y2,x,y], rest) -> (x1,y1) :: (x2,y2) :: (x,y) :: toPointValPairs rest
                _                         -> let _ = Utils.log "toPointValPairs C parse fail" in []
            else if commandIsAnyOf cmd "SQ" then
              case Utils.split 4 rest of
                ([x1,y1,x,y], rest) -> (x1,y1) :: (x,y) :: toPointValPairs rest
                _                   -> let _ = Utils.log "toPointValPairs SQ parse fail" in []
            else if commandIsAnyOf cmd "A" then
              case Utils.split 7 rest of
                ([rx,ry,axis,flag,sweep,x,y], rest) -> (x,y) :: toPointValPairs rest
                _                                   -> let _ = Utils.log "toPointValPairs A parse fail" in []
            else
              let _ = Utils.log ("toPointValPairs bad command " ++ cmd) in
              []

          _ ->
            let _ = Utils.log ("toPointValPairs expected command string, got " ++ strVal v) in
            []
    in
    case (Utils.find "featureValEquation: getPathPoint d" attrList "d").val.v_ of
      VList cmds -> toPointValPairs cmds |> Utils.geti i
      _          -> Debug.crash "featureValEquation: getPathPoint2"
  in
  let getPolyPoint attrList i =
    case (Utils.find "featureValEquation: getPolyPoint" attrList "points").val.v_ of
      VList points ->
        case (Utils.geti i points).v_ of
          VList [xVal, yVal] -> (xVal, yVal)
          _                  -> Debug.crash "featureValEquation: getPolyPoint2"
      _            -> Debug.crash "featureValEquation: getPolyPoint3"
  in
  let toOpacity attrVal =
    case attrVal.val.v_ of
      VList [_, opacityVal] -> opacityVal
      _                     -> Debug.crash "featureValEquation: toOpacity"
  in
  let toTransformRot attrVal =
    case attrVal.val.v_ of
      VList [cmd, rot, cx, cy] -> if cmd.v_ == VBase (VString "rotate") then (rot, cx, cy) else Debug.crash "featureValEquation: bad rotate command"
      _                        -> Debug.crash "featureValEquation: toTransformRot"
  in
  featureEquationOf
      getAttr
      getPathPoint
      getPolyPoint
      toOpacity
      toTransformRot
      twoVal
      kind
      nodeAttrs
      featureNum


widgetFeatureEquation : ShapeFeature -> Widget -> Dict.Dict LocId (Num, Loc) -> FeatureEquation
widgetFeatureEquation shapeFeature widget locIdToNumberAndLoc =
  case widget of
    WIntSlider low high caption curVal provenance (locId,_,_) _ ->
      let (n, loc) =
        Utils.justGet_ "ShapeWidgets.widgetFeatureEquation" locId locIdToNumberAndLoc
      in
      EqnNum (n, TrLoc loc)
    WNumSlider low high caption curVal provenance (locId,_,_) _ ->
      let (n, loc) =
        Utils.justGet_ "ShapeWidgets.widgetFeatureEquation" locId locIdToNumberAndLoc
      in
      EqnNum (n, TrLoc loc)
    WPoint (x, xTr) xProvenance (y, yTr) yProvenance ->
      let featureNum = parseFeatureNum shapeFeature in
      case featureNum of
        XFeat LonePoint -> EqnNum (x, xTr)
        YFeat LonePoint -> EqnNum (y, yTr)
        _               -> Debug.crash <| "WPoint only supports XFeat LonePoint and YFeat LonePoint; but asked for " ++ toString shapeFeature
    WOffset1D (baseX, baseXTr) (baseY, baseYTr) axis sign (amount, amountTr) amountProvenance endXProvenance endYProvenance ->
      let featureNum = parseFeatureNum shapeFeature in
      let op =
        case sign of
          Positive -> Plus
          Negative -> Minus
      in
      case (featureNum, axis) of
        (DFeat Offset, _)   -> EqnNum (amount, amountTr)
        (XFeat EndPoint, X) -> EqnOp op [EqnNum (baseX, baseXTr), EqnNum (amount, amountTr)]
        (XFeat EndPoint, Y) -> EqnNum (baseX, baseXTr)
        (YFeat EndPoint, X) -> EqnNum (baseY, baseYTr)
        (YFeat EndPoint, Y) -> EqnOp op [EqnNum (baseY, baseYTr), EqnNum (amount, amountTr)]
        _                   -> Debug.crash <| "WOffset1D only supports DFeat Offset, XFeat EndPoint, and YFeat EndPoint; but asked for " ++ toString shapeFeature
    WCall funcVal argVals retVal retWs ->
      Debug.crash <| "WCall does not have any feature equations, but asked for " ++ toString shapeFeature


widgetFeatureValEquation : ShapeFeature -> Widget -> Dict.Dict LocId (Num, Loc) -> FeatureValEquation
widgetFeatureValEquation shapeFeature widget locIdToNumberAndLoc =
  case widget of
    WIntSlider low high caption curVal valVal (locId,_,_) _ -> EqnNum valVal
    WNumSlider low high caption curVal valVal (locId,_,_) _ -> EqnNum valVal
    WPoint (x, xTr) xVal (y, yTr) yVal ->
      let featureNum = parseFeatureNum shapeFeature in
      case featureNum of
        XFeat LonePoint -> EqnNum xVal
        YFeat LonePoint -> EqnNum yVal
        _               -> Debug.crash <| "widgetFeatureValEquation WPoint only supports XFeat LonePoint and YFeat LonePoint; but asked for " ++ toString shapeFeature
    WOffset1D (baseX, baseXTr) (baseY, baseYTr) axis sign (amount, amountTr) amountVal endXVal endYVal ->
      let featureNum = parseFeatureNum shapeFeature in
      let op =
        case sign of
          Positive -> Plus
          Negative -> Minus
      in
      case featureNum of
        DFeat Offset   -> EqnNum amountVal
        XFeat EndPoint -> EqnNum endXVal
        YFeat EndPoint -> EqnNum endYVal
        _              -> Debug.crash <| "widgetFeatureValEquation WOffset1D only supports DFeat Offset, XFeat EndPoint, and YFeat EndPoint; but asked for " ++ toString shapeFeature
    WCall funcVal argVals retVal retWs ->
      Debug.crash <| "WCall does not have any feature val equations, but asked for " ++ toString shapeFeature


featureEquationOf
  :  (String -> List Attr -> a)
  -> (List Attr -> Int -> (a, a))
  -> (List Attr -> Int -> (a, a))
  -> (AVal -> a)
  -> (AVal -> (a, a, a))
  -> FeatureEquationOf a
  -> ShapeKind
  -> List Attr
  -> FeatureNum
  -> FeatureEquationOf a
featureEquationOf getAttrNum getPathPoint getPolyPoint toOpacity toTransformRot two kind attrs featureNum =

  let get attr  = EqnNum <| getAttrNum attr attrs in
  let crash _ = -- Elm compiler crashes if this is instead written as "let crash () ="
    Debug.crash <| Utils.spaces [ "featureEquationOf:", kind, toString featureNum ] in

  let handleLine () =
    case featureNum of
      XFeat (Point 1) -> get "x1"
      XFeat (Point 2) -> get "x2"
      YFeat (Point 1) -> get "y1"
      YFeat (Point 2) -> get "y2"
      XFeat Center    -> div (plus (get "x1") (get "x2")) two
      YFeat Center    -> div (plus (get "y1") (get "y2")) two
      _           -> crash () in

  let handleBoxyShape () =
    let equations = boxyFeatureEquationsOf getAttrNum two kind attrs in
    case featureNum of

      XFeat TopLeft   -> equations.left
      YFeat TopLeft   -> equations.top
      XFeat TopRight  -> equations.right
      YFeat TopRight  -> equations.top
      XFeat BotLeft   -> equations.left
      YFeat BotLeft   -> equations.bottom
      XFeat BotRight  -> equations.right
      YFeat BotRight  -> equations.bottom
      XFeat TopEdge   -> equations.cx
      YFeat TopEdge   -> equations.top
      XFeat BotEdge   -> equations.cx
      YFeat BotEdge   -> equations.bottom
      XFeat LeftEdge  -> equations.left
      YFeat LeftEdge  -> equations.cy
      XFeat RightEdge -> equations.right
      YFeat RightEdge -> equations.cy
      XFeat Center    -> equations.cx
      YFeat Center    -> equations.cy

      DFeat distanceFeature ->
        let cap = Utils.spaces ["shapeFeatureEquationOf:", kind, toString featureNum] in
        case distanceFeature of
          Width     -> Utils.fromJust_ cap equations.mWidth
          Height    -> Utils.fromJust_ cap equations.mHeight
          Radius    -> Utils.fromJust_ cap equations.mRadius
          RadiusX   -> Utils.fromJust_ cap equations.mRadiusX
          RadiusY   -> Utils.fromJust_ cap equations.mRadiusY
          _         -> crash ()

      _ -> crash () in

  let handlePath () =
    let x i = EqnNum <| Tuple.first <| getPathPoint attrs i in
    let y i = EqnNum <| Tuple.second <| getPathPoint attrs i in
    case featureNum of
      XFeat (Point i) -> x i
      YFeat (Point i) -> y i
      _           -> crash () in

  let handlePoly () =
    let ptCount = LangSvg.getPtCount attrs in
    let x i = EqnNum <| Tuple.first <| getPolyPoint attrs i in
    let y i = EqnNum <| Tuple.second <| getPolyPoint attrs i in
    case featureNum of

      XFeat (Point i) -> x i
      YFeat (Point i) -> y i

      XFeat (Midpoint i1) ->
        let i2 = if i1 == ptCount then 1 else i1 + 1 in
        div (plus (x i1) (x i2)) two
      YFeat (Midpoint i1) ->
        let i2 = if i1 == ptCount then 1 else i1 + 1 in
        div (plus (y i1) (y i2)) two

      _  -> crash () in

  case featureNum of

    OFeat FillColor   -> get "fill"
    OFeat StrokeColor -> get "stroke"
    OFeat StrokeWidth -> get "stroke-width"

    OFeat FillOpacity   -> EqnNum <| toOpacity <| Utils.find_ attrs "fill"
    OFeat StrokeOpacity -> EqnNum <| toOpacity <| Utils.find_ attrs "stroke"
    OFeat Rotation ->
      let (rot,cx,cy) = toTransformRot <| Utils.find_ attrs "transform" in
      EqnNum rot

    _ ->
      case kind of
        "line"     -> handleLine ()
        "polygon"  -> handlePoly ()
        "polyline" -> handlePoly ()
        "path"     -> handlePath ()
        "rect"     -> handleBoxyShape ()
        "BOX"      -> handleBoxyShape ()
        "circle"   -> handleBoxyShape ()
        "ellipse"  -> handleBoxyShape ()
        "OVAL"     -> handleBoxyShape ()
        _          -> crash ()


boxyFeatureEquationsOf : (String -> List Attr -> a) -> FeatureEquationOf a -> ShapeKind -> List Attr -> BoxyFeatureEquationsOf a
boxyFeatureEquationsOf getAttrNum two kind attrs =
  let get attr  = EqnNum <| getAttrNum attr attrs in
  case kind of

    "rect" ->
      { left     = get "x"
      , top      = get "y"
      , right    = plus (get "x") (get "width")
      , bottom   = plus (get "y") (get "height")
      , cx       = plus (get "x") (div (get "width") two)
      , cy       = plus (get "y") (div (get "height") two)
      , mWidth   = Just <| get "width"
      , mHeight  = Just <| get "height"
      , mRadius  = Nothing
      , mRadiusX = Nothing
      , mRadiusY = Nothing
      }

    "BOX" ->
      { left     = get "LEFT"
      , top      = get "TOP"
      , right    = get "RIGHT"
      , bottom   = get "BOT"
      , cx       = div (plus (get "LEFT") (get "RIGHT")) two
      , cy       = div (plus (get "TOP") (get "BOT")) two
      , mWidth   = Just <| minus (get "RIGHT") (get "LEFT")
      , mHeight  = Just <| minus (get "BOT") (get "TOP")
      , mRadius  = Nothing
      , mRadiusX = Nothing
      , mRadiusY = Nothing
      }

    "OVAL" ->
      { left     = get "LEFT"
      , top      = get "TOP"
      , right    = get "RIGHT"
      , bottom   = get "BOT"
      , cx       = div (plus (get "LEFT") (get "RIGHT")) two
      , cy       = div (plus (get "TOP") (get "BOT")) two
      , mWidth   = Nothing
      , mHeight  = Nothing
      , mRadius  = Nothing
      , mRadiusX = Just <| div (minus (get "RIGHT") (get "LEFT")) two
      , mRadiusY = Just <| div (minus (get "BOT") (get "TOP")) two
      }

    "circle" ->
      { left     = minus (get "cx") (get "r")
      , top      = minus (get "cy") (get "r")
      , right    = plus (get "cx") (get "r")
      , bottom   = plus (get "cy") (get "r")
      , cx       = get "cx"
      , cy       = get "cy"
      , mWidth   = Nothing
      , mHeight  = Nothing
      , mRadius  = Just <| get "r"
      , mRadiusX = Nothing
      , mRadiusY = Nothing
      }

    "ellipse" ->
      { left     = minus (get "cx") (get "rx")
      , top      = minus (get "cy") (get "ry")
      , right    = plus (get "cx") (get "rx")
      , bottom   = plus (get "cy") (get "ry")
      , cx       = get "cx"
      , cy       = get "cy"
      , mWidth   = Nothing
      , mHeight  = Nothing
      , mRadius  = Nothing
      , mRadiusX = Just <| get "rx"
      , mRadiusY = Just <| get "ry"
      }

    _ -> Debug.crash <| "boxyFeatureEquationsOf: " ++ kind


evaluateFeatureEquation : FeatureEquation -> Maybe Num
evaluateFeatureEquation eqn =
  case eqn of
    EqnNum (n, _) ->
      Just n

    EqnOp op [left, right] ->
      let maybePerformBinop op =
        let maybeLeftResult = evaluateFeatureEquation left in
        let maybeRightResult = evaluateFeatureEquation right in
        case (maybeLeftResult, maybeRightResult) of
          (Just leftResult, Just rightResult) -> Just (op leftResult rightResult)
          _                                   -> Nothing
      in
      case op of
        Plus  -> maybePerformBinop (+)
        Minus -> maybePerformBinop (-)
        Mult  -> maybePerformBinop (*)
        Div   -> maybePerformBinop (/)
        _     -> Nothing

    _ -> Nothing


evaluateFeatureEquation_ =
  Utils.fromJust_ "evaluateFeatureEquation_" << evaluateFeatureEquation


evaluateLineFeatures attrs =
  [ XFeat (Point 1), YFeat (Point 1)
  , XFeat (Point 2), YFeat (Point 2)
  , XFeat Center, YFeat Center
  ]
  |> List.map (\featureNum -> featureEquation ("line", featureNum) attrs |> evaluateFeatureEquation_)
  |> Utils.unwrap6


type alias BoxyNums =
  { left : Num , top : Num , right : Num , bot : Num , width : Num , height : Num
  , cx : Num , cy : Num
  , rx : Num , ry : Num , r : Num
  }


evaluateBoxyNums kind attrs =
  let equations = boxyFeatureEquationsOf LangSvg.findNumishAttr twoNumTr kind attrs in
  let (left, top, right, bot, cx, cy) =
    ( evaluateFeatureEquation_ equations.left
    , evaluateFeatureEquation_ equations.top
    , evaluateFeatureEquation_ equations.right
    , evaluateFeatureEquation_ equations.bottom
    , evaluateFeatureEquation_ equations.cx
    , evaluateFeatureEquation_ equations.cy
    )
  in
  let
    width  = right - left
    height = bot - top
    rx     = width / 2
    ry     = height / 2
  in
  { left = left, top = top, right = right, bot = bot
  , width = width, height = height
  , cx = cx, cy = cy
  , rx = rx, ry = ry
  , r = rx
  }


------------------------------------------------------------------------------
-- Point Feature Equations

type alias PointEquations = (FeatureEquation, FeatureEquation)

getPointEquations : ShapeKind -> List Attr -> PointFeature -> PointEquations
getPointEquations kind attrs pointFeature =
  ( featureEquation (kind, XFeat pointFeature) attrs
  , featureEquation (kind, XFeat pointFeature) attrs )

getPrimitivePointEquations : RootedIndexedTree -> NodeId -> List (NumTr, NumTr)
getPrimitivePointEquations (_, tree) nodeId =
  case Utils.justGet_ "LangSvg.getPrimitivePoints" nodeId tree |> .interpreted of
    LangSvg.SvgNode kind attrs _ ->
      List.concatMap (\pointFeature ->
        case getPointEquations kind attrs pointFeature of
          (EqnNum v1, EqnNum v2) -> [(v1,v2)]
          _                      -> []
      ) (pointFeaturesOfShape kind attrs)
    _ ->
      Debug.crash "LangSvg.getPrimitivePoints"


------------------------------------------------------------------------------
-- Shape Bounds

-- Enclosing bounding box
enclosureOfBoundsPair : (Num, Num, Num, Num) -> (Num, Num, Num, Num) -> (Num, Num, Num, Num)
enclosureOfBoundsPair (left1, top1, right1, bot1) (left2, top2, right2, bot2) =
  ( min  left1  left2
  , min   top1   top2
  , max right1 right2
  , max   bot1   bot2
  )

maybeEnclosureOfAllBounds : List (Num, Num, Num, Num) -> Maybe (Num, Num, Num, Num)
maybeEnclosureOfAllBounds bounds =
  case bounds of
    []          -> Nothing
    first::rest -> Just (rest |> List.foldl enclosureOfBoundsPair first)


valToMaybeBounds : Val -> Maybe (Num, Num, Num, Num)
valToMaybeBounds val =
  case valToMaybeAnnotatedPoint val of
    Just (x, y) -> Just (x, y, x, y)
    Nothing ->
      case val.v_ of
        VList vals ->
          case LangSvg.valToIndexedTree val of
            Ok (_, shapeDict) ->
              let shapeNodes = Dict.values shapeDict in
              shapeNodes
              |> List.filterMap maybeShapeBounds
              |> maybeEnclosureOfAllBounds

            Err _ ->
              -- Maybe this is a list of shapes or points?
              vals
              |> List.filterMap valToMaybeBounds
              |> maybeEnclosureOfAllBounds -- Returns nothing if input list empty (no shapes found)
        _ -> Nothing


valToMaybeAnnotatedPoint : Val -> Maybe (Num, Num)
valToMaybeAnnotatedPoint val =
  case val.v_ of
    VConst (Just (X, (y, _), _)) (x, _) -> Just (x, y)
    VConst (Just (Y, (x, _), _)) (y, _) -> Just (x, y)
    VList vals ->
      case List.map .v_ vals of
        [ VConst (Just (X, _, _)) (x, _)
        , VConst (Just (Y, _, _)) (y, _) ] -> Just (x, y)
        _                             -> Nothing
    _ -> Nothing


-- Returns Maybe (left, top, right, bot)
maybeShapeBounds : LangSvg.IndexedTreeNode -> Maybe (Num, Num, Num, Num)
maybeShapeBounds svgNode =
  case svgNode.interpreted of
    LangSvg.TextNode _ -> Nothing
    LangSvg.SvgNode shapeKind shapeAttrs childIds ->
      let (xs, ys) =
        featuresOfShape shapeKind shapeAttrs
        |> List.filterMap
            (\feature ->
              case feature of
                PointFeature pf ->
                  let (xEqn, yEqn) = getPointEquations shapeKind shapeAttrs pf in
                  case (evaluateFeatureEquation xEqn, evaluateFeatureEquation yEqn) of
                    (Just x, Just y) -> Just (x, y)
                    _                -> Nothing

                _ -> Nothing
            )
        |> List.unzip
      in
      case Utils.projJusts [ List.minimum xs, List.minimum ys, List.maximum xs, List.maximum ys ] of
        Just [ left, top, right, bot ] -> Just (left, top, right, bot)
        _                              -> Nothing


-- Returns Maybe (left, top, right, bot)
maybeWidgetBounds : Widget -> Maybe (Num, Num, Num, Num)
maybeWidgetBounds widget =
  case widget of
    WIntSlider _ _ _ _ _ _ _     -> Nothing
    WNumSlider _ _ _ _ _ _ _     -> Nothing
    WPoint (x, xTr) _ (y, yTr) _ -> Just (x, y, x, y)
    WOffset1D (baseX, baseXTr) (baseY, baseYTr) axis sign (amount, amountTr) _ _ _ ->
      let (effectiveAmount, ((endX, endXTr), (endY, endYTr))) =
        offsetWidget1DEffectiveAmountAndEndPoint ((baseX, baseXTr), (baseY, baseYTr)) axis sign (amount, amountTr)
      in
      Just
          ( min baseX endX
          , min baseY endY
          , max baseX endY
          , max baseY endY
          )

    WCall _ _ _ _ -> Nothing


------------------------------------------------------------------------------
-- Zones

type RealZone
  = ZInterior
  | ZPoint PointFeature
  | ZLineEdge
  | ZPolyEdge Int
  | ZOther OtherFeature   -- fill and stroke sliders
  | ZSlider               -- range annotations
  | ZOffset1D


realZoneDesc : RealZone -> String
realZoneDesc realZone =
  toString realZone
  |> Utils.stringReplace " " ""
  |> Utils.stringReplace "(" ""
  |> Utils.stringReplace ")" ""


------------------------------------------------------------------------------
-- Relating Zones and Shape Point Features

-- In View, may want to create a single SVG element for points
-- that double as selection and drag widgets. If so, then
-- eliminate this connection.
--
zoneToCrosshair : ShapeKind -> RealZone -> Maybe (ShapeFeature, ShapeFeature)
zoneToCrosshair shapeKind realZone =
  case realZone of
    ZPoint point ->
      let xFeature = (shapeKind, XFeat point) in
      let yFeature = (shapeKind, YFeat point) in
      Just (xFeature, yFeature)
    _ ->
      Nothing


------------------------------------------------------------------------------
-- Params for Shape Widget Sliders (needed by Sync and View)

wColorSlider = 250
wStrokeWidthSlider = 60
wOpacitySlider = 20


------------------------------------------------------------------------------
-- Mapping ouput selections to code EIds for synthesis suggestions.

featureValEquationToValTree : FeatureValEquation -> Val
featureValEquationToValTree valEqn =
  case valEqn of
    EqnNum val        -> val
    EqnOp op children ->
      let childVals = List.map featureValEquationToValTree children in
      -- Only need Provenance basedOn list and the EId of the expression (dummy here)
      { v_         = VList []
      , provenance = Provenance [] (eTuple []) childVals
      , parents    = Parents []
      }

-- Combinatorical explosion of interpretations.
featureValEquationToEIdSets : (Exp -> Bool) -> FeatureValEquation -> List (Set EId)
featureValEquationToEIdSets expFilter valEqn =
  valEqn
  |> featureValEquationToValTree
  |> Provenance.valTreeToAllProgramEIdInterpretationsIgnoringUninterpretedSubtrees expFilter
  -- |> Debug.log "eids"

featureValEquationToProximalDistalEIdSets : (Exp -> Bool) -> FeatureValEquation -> (Set EId, Set EId)
featureValEquationToProximalDistalEIdSets expFilter valEqn =
  let valTree = valEqn |> featureValEquationToValTree in
  ( Provenance.valTreeToMostProximalProgramEIdInterpretation expFilter valTree
  , Provenance.valTreeToMostDistalProgramEIdInterpretation expFilter valTree
  )

featureValEquationToSingleEIds : Exp -> (Exp -> Bool) -> FeatureValEquation -> List EId
featureValEquationToSingleEIds program expFilter valEqn =
  valEqn
  |> featureValEquationToValTree
  |> Provenance.valTreeToSingleEIdInterpretations program expFilter

-- Only two interpretations: most proximal for each feature, and most distal.
selectionsProximalDistalEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> List (List EId)
selectionsProximalDistalEIdInterpretations program slate widgets selectedFeatures selectedShapes selectedBlobs =
  let (proximalInterps, distalInterps) =
    selectionsProximalDistalEIdInterpretations_ program slate widgets selectedFeatures selectedShapes selectedBlobs (always True)
  in
  proximalInterps ++ distalInterps |> Utils.dedup

selectionsProximalEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> List (List EId)
selectionsProximalEIdInterpretations program slate widgets selectedFeatures selectedShapes selectedBlobs =
  let (proximalInterps, distalInterps) =
    selectionsProximalDistalEIdInterpretations_ program slate widgets selectedFeatures selectedShapes selectedBlobs (always True)
  in
  proximalInterps

selectionsDistalEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> (Exp -> Bool) -> List (List EId)
selectionsDistalEIdInterpretations program slate widgets selectedFeatures selectedShapes selectedBlobs expFilter =
  let (proximalInterps, distalInterps) =
    selectionsProximalDistalEIdInterpretations_ program slate widgets selectedFeatures selectedShapes selectedBlobs expFilter
  in
  proximalInterps

selectionsUniqueProximalEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> List (List EId)
selectionsUniqueProximalEIdInterpretations program ((rootI, shapeTree) as slate) widgets selectedFeatures selectedShapes selectedBlobs =
  let eidsToNotSelect =
    -- If any shapes selected, diff against all other shapes.
    let shapeProvenanceEIdsNotToSelect =
      let effectiveSelectedNodeIds =
        let selectedDescendentIds =
          selectedShapes
          |> Set.toList
          |> List.filterMap (\nodeId -> Dict.get nodeId shapeTree)
          |> List.concatMap (LangSvg.descendantNodeIds shapeTree)
          |> Set.fromList
        in
        Set.union
            selectedShapes
            selectedDescendentIds
      in
      if Set.size selectedShapes == 0 then
        Set.empty
      else
        shapeTree
        |> Dict.toList
        |> List.filter (\(nodeId, shape) -> not <| Utils.anyOverlap [Set.singleton nodeId, Set.fromList (LangSvg.descendantNodeIds shapeTree shape), effectiveSelectedNodeIds])
        |> List.map (\(nodeId, shape) -> shape.val)
        |> List.concatMap Provenance.flattenValBasedOnTree
        |> List.map (valExp >> .val >> .eid)
        -- |> List.map valExp
        -- |> List.filter (.val >> .eid >> FastParser.isProgramEId)
        -- |> List.map (\e -> let _ = Utils.log (LangUnparser.unparse e) in e)
        -- |> List.map (.val >> .eid)
        |> Set.fromList
    in
    -- TODO: If any features selected, diff against all other analogous features on other shapes.
    let featureProvenanceEIdsNotToSelect =
      if Set.size selectedFeatures == 0 then
        Set.empty
      else
        Set.empty
    in
    Set.union shapeProvenanceEIdsNotToSelect featureProvenanceEIdsNotToSelect
  in
  let expFilter exp =
    -- Exclude expressions touched by shapes NOT selected
    not <| Set.member exp.val.eid eidsToNotSelect
  in
  let (proximalInterps, distalInterps) =
    selectionsProximalDistalEIdInterpretations_ program slate widgets selectedFeatures selectedShapes selectedBlobs expFilter
  in
  proximalInterps

-- EIds in interp must satisfy the predicate.
selectionsProximalDistalEIdInterpretations_ : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> (Exp -> Bool) -> (List (List EId), List (List EId))
selectionsProximalDistalEIdInterpretations_ program slate widgets selectedFeatures selectedShapes selectedBlobs expFilter =
  let (featureProximalEIds, featureDistalEIds) =
    selectedFeaturesToProximalDistalEIdInterpretations program slate widgets (Set.toList selectedFeatures) expFilter
  in
  let (otherProximalEIds, otherDistalEIds) =
    [ selectedShapesToProximalDistalEIdInterpretations program slate (Set.toList selectedShapes) expFilter
    , selectedBlobsToProximalDistalEIdInterpretations  program slate (Dict.toList selectedBlobs) expFilter
    ]
    |> List.unzip
    |> Utils.mapBoth Utils.unionAll
  in
  let (pointProximalInterps, pointDistalInterps) =
    selectedFeaturesToProximalDistalPointEIdInterpretations program slate widgets (Set.toList selectedFeatures) expFilter
  in
  -- Point interps first.
  ( List.map (Set.union otherProximalEIds) pointProximalInterps ++ [Set.union featureProximalEIds otherProximalEIds] |> List.map Set.toList |> Utils.dedup
  , List.map (Set.union otherDistalEIds)   pointDistalInterps   ++ [Set.union featureDistalEIds   otherDistalEIds]   |> List.map Set.toList |> Utils.dedup
  )


-- Combinatorical explosion of interpretations.
selectionsEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> (Exp -> Bool) -> List (List EId)
selectionsEIdInterpretations program ((rootI, shapeTree) as slate) widgets selectedFeatures selectedShapes selectedBlobs expFilter =
  selectedFeaturesToEIdInterpretationLists program slate widgets (Set.toList selectedFeatures) expFilter ++
  selectedShapesToEIdInterpretationLists   program slate widgets (Set.toList selectedShapes)   expFilter ++
  selectedBlobsToEIdInterpretationLists    program slate widgets (Dict.toList selectedBlobs)   expFilter
  |> Utils.oneOfEach
  |> List.map Utils.unionAll
  |> List.map Set.toList
  |> Utils.dedup


selectionsEIdsTouched : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> (Exp -> Bool) -> List EId
selectionsEIdsTouched program ((rootI, shapeTree) as slate) widgets selectedFeatures selectedShapes selectedBlobs expFilter =
  [ selectedFeaturesValTrees slate widgets (Set.toList selectedFeatures)
  , selectedShapesValTrees   slate         (Set.toList selectedShapes)
  , selectedBlobsValTrees    slate         (Dict.toList selectedBlobs)
  ]
  |> List.concat
  |> List.concatMap Provenance.flattenValBasedOnTree
  |> List.map valExp
  |> List.filter expFilter
  |> List.map (.val >> .eid)
  |> Utils.dedup


-- Try to find single EIds in the program that explain everything selected.
selectionsSingleEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> Set SelectedShapeFeature -> Set NodeId -> Dict.Dict Int NodeId -> (Exp -> Bool) -> List EId
selectionsSingleEIdInterpretations program ((rootI, shapeTree) as slate) widgets selectedFeatures selectedShapes selectedBlobs expFilter =
  let
    possibleExps = program |> flattenExpTree |> List.filter expFilter

    valTrees =
      [ selectedFeaturesValTrees slate widgets (Set.toList selectedFeatures)
      , selectedShapesValTrees   slate         (Set.toList selectedShapes)
      , selectedBlobsValTrees    slate         (Dict.toList selectedBlobs)
      ] |> List.concat

    directSingleEIdInterpretations =
      -- Checking exp-by-exp avoids combinatorical explosion of building all interpretations and then filtering.
      possibleExps
      |> List.filter (\exp -> valTrees |> List.all (Provenance.isPossibleSingleEIdInterpretation program exp.val.eid))
      |> List.map (.val >> .eid)

    valExpIsInProgram val = valExp val |> .val |> .eid |> FastParser.isProgramEId

    parentSingleEIdInterpretations =
      case valTrees of
        []          -> []
        first::_ ->
          let possibleParentVals = Provenance.flattenValBasedOnTree first |> List.concatMap valParents |> List.filter valExpIsInProgram |> Utils.dedup in
          let firstNonTrivialChildren val =
            case childVals val of
              []               -> [val]
              [singleChild]    -> firstNonTrivialChildren singleChild
              multipleChildren -> multipleChildren
          in
          possibleParentVals
          -- |> List.map (\parentVal -> let _ = Utils.log <| (++) "Possible parent: " <| LangUnparser.unparse <| valExp parentVal in parentVal)
          |> List.filter
              (\parentVal ->
                let domain = flattenValTree parentVal in
                let coveringsStillNeeded = [firstNonTrivialChildren parentVal] in
                -- Try to cover the parent's children with interpretations.
                let maybeNeededAfterCovering =
                  valTrees
                  |> Utils.foldlMaybe
                      (\valTree coveringsStillNeeded ->
                      --   let valInterps = Provenance.valInterpretationsAllInside domain valTree in
                      --   -- Remove interpretations subsumed by a more proximal interpretation.
                      --   let valInterpsSimplified =
                      --     valInterps
                      --     |> List.foldl
                      --         (\valInterp valInterps ->
                      --           valInterps
                      --           |> List.filter (\existingValInterp -> not (valInterp /= existingValInterp && Utils.isSublistAsSet existingValInterp (List.concatMap flattenValTree valInterp)))
                      --         )
                      --         valInterps
                      --   in
                        let valInterpsSimplified = Provenance.proximalValInterpretationsAllInside domain valTree in
                        case valInterpsSimplified of
                          [] -> Nothing -- Value can't be interpreted inside parent, give up on this parent.
                          _  ->
                            Utils.cartProd coveringsStillNeeded valInterpsSimplified
                            |> List.map (\(aCoveringNeeded, valInterp) -> Utils.diffAsSet aCoveringNeeded (List.concatMap flattenValTree valInterp))
                            |> Utils.dedup
                            |> Just
                      )
                      (Just coveringsStillNeeded)
                in
                case maybeNeededAfterCovering of
                  Nothing                   -> False
                  Just coveringsStillNeeded -> List.any ((==) []) coveringsStillNeeded
              )
          -- |> List.map (\parentVal -> let _ = Utils.log <| (++) "Passing parent: " <| LangUnparser.unparse <| valExp parentVal in parentVal)
          |> List.map (valExp >> .val >> .eid)
  in
  directSingleEIdInterpretations ++ parentSingleEIdInterpretations

-- Heuristic: Closest and farthest interpretation only.
selectedFeaturesToProximalDistalEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> List SelectedShapeFeature -> (Exp -> Bool) -> (Set EId, Set EId)
selectedFeaturesToProximalDistalEIdInterpretations program ((rootI, shapeTree) as slate) widgets selectedFeatures expFilter =
  let (proximalEIdSets, distalEIdSets) =
    selectedFeatures
    |> List.map
        (\(nodeId, shapeFeature) ->
          selectedShapeFeatureToValEquation (nodeId, shapeFeature) shapeTree widgets Dict.empty
          |> Utils.fromJust_ "selectedFeaturesToEIdLists: can't make feature into val equation"
          |> featureValEquationToProximalDistalEIdSets expFilter
        )
    |> List.unzip
  in
  ( Utils.unionAll proximalEIdSets
  , Utils.unionAll distalEIdSets
  )

-- Returns multiple proximal and distal interpretations (b/c of some edge cases where most proximal/distal for x is not the most proximal/distal for y).
--
-- Features not part of points are still interpretated.
selectedFeaturesToProximalDistalPointEIdInterpretations : Exp -> RootedIndexedTree -> Widgets -> List SelectedShapeFeature -> (Exp -> Bool) -> (List (Set EId), List (Set EId))
selectedFeaturesToProximalDistalPointEIdInterpretations program ((rootI, shapeTree) as slate) widgets selectedFeatures expFilter =
  let recurse remainingFeatures =
    selectedFeaturesToProximalDistalPointEIdInterpretations program slate widgets remainingFeatures expFilter
  in
  case selectedFeatures of
    [] -> ([Set.empty], [Set.empty])
    selectedShapeFeature::rest ->
      let returnNotPartOfAPoint () =
        let (thisProximalInterp, thisDistalInterp) =
          selectedShapeFeatureToValEquation selectedShapeFeature shapeTree widgets Dict.empty
          |> Utils.fromJust_ "selectedFeaturesToProximalDistalPointEIdInterpretations0: can't make feature into val equation"
          |> featureValEquationToProximalDistalEIdSets expFilter
        in
        let (remainingProximalInterps, remainingDistalInterps) = recurse rest in
        ( remainingProximalInterps |> List.map (Set.union thisProximalInterp)
        , remainingDistalInterps   |> List.map (Set.union thisDistalInterp)
        )
      in
      -- Try to interpret as point?
      case rest |> Utils.findFirst (\otherSelectedShapeFeature -> selectedShapeFeaturesAreXYPairs selectedShapeFeature otherSelectedShapeFeature) of
        Just otherSelectedShapeFeature ->
          let (xSelectedShapeFeature, ySelectedShapeFeature) =
            if selectedShapeFeatureIsX selectedShapeFeature
            then (selectedShapeFeature, otherSelectedShapeFeature)
            else (otherSelectedShapeFeature, selectedShapeFeature)
          in
          let xValEqn = selectedShapeFeatureToValEquation xSelectedShapeFeature shapeTree widgets Dict.empty |> Utils.fromJust_ "selectedFeaturesToEIdLists1: can't make feature into val equation" in
          let yValEqn = selectedShapeFeatureToValEquation ySelectedShapeFeature shapeTree widgets Dict.empty |> Utils.fromJust_ "selectedFeaturesToEIdLists2: can't make feature into val equation" in
          let xValTree = featureValEquationToValTree xValEqn in
          let yValTree = featureValEquationToValTree yValEqn in
          let (proximalInterp1, proximalInterp2, distalInterp1, distalInterp2) =
            Provenance.valsToProximalDistalPointInterpretations expFilter xValTree yValTree
          in
          -- If code written correctly, there should be a proximal interp iff there is an distal interp.
          if (proximalInterp1 /= Set.empty || proximalInterp2 /= Set.empty) && (distalInterp1 /= Set.empty || distalInterp2 /= Set.empty) then
            let (remainingProximalInterps, remainingDistalInterps) = recurse (Utils.removeAsSet otherSelectedShapeFeature rest) in
            ( remainingProximalInterps |> Utils.cartProd (List.filter ((/=) Set.empty) [proximalInterp1, proximalInterp2] |> Utils.dedup) |> List.map (uncurry Set.union)
            , remainingDistalInterps   |> Utils.cartProd (List.filter ((/=) Set.empty) [distalInterp1,   distalInterp2]   |> Utils.dedup) |> List.map (uncurry Set.union)
            )
          else if proximalInterp1 /= Set.empty || proximalInterp2 /= Set.empty then
            Debug.crash <| "selectedFeaturesToProximalDistalPointEIdInterpretations: proximal interpretation exists but distal does not!\n" ++ toString (proximalInterp1, proximalInterp2, distalInterp1, distalInterp2)
          else if distalInterp1 /= Set.empty || distalInterp2 /= Set.empty then
            Debug.crash <| "selectedFeaturesToProximalDistalPointEIdInterpretations: distal interpretation exists but proximal does not!\n" ++ toString (proximalInterp1, proximalInterp2, distalInterp1, distalInterp2)
          else
            returnNotPartOfAPoint ()

        Nothing ->
          returnNotPartOfAPoint ()


-- No special handling of points.
selectedFeaturesValTrees : RootedIndexedTree -> Widgets -> List SelectedShapeFeature -> List Val
selectedFeaturesValTrees ((rootI, shapeTree) as slate) widgets selectedFeatures =
  selectedFeatures
  |> List.map
      (\(nodeId, shapeFeature) ->
        selectedShapeFeatureToValEquation (nodeId, shapeFeature) shapeTree widgets Dict.empty
        |> Utils.fromJust_ "selectedShapesToEIdInterpretationLists: can't make shape into val equation"
        |> featureValEquationToValTree
      )



-- Combinatorical explosion of interpretations.
selectedFeaturesToEIdInterpretationLists : Exp -> RootedIndexedTree -> Widgets -> List SelectedShapeFeature -> (Exp -> Bool) -> List (List (Set EId))
selectedFeaturesToEIdInterpretationLists program ((rootI, shapeTree) as slate) widgets selectedFeatures expFilter =
  let recurse remainingFeatures =
    selectedFeaturesToEIdInterpretationLists program slate widgets remainingFeatures expFilter
  in
  case selectedFeatures of
    [] -> []
    selectedShapeFeature::rest ->
      let eidSets = featureValEquationToEIdSets expFilter <| Utils.fromJust_ "selectedFeaturesToEIdLists: can't make feature into val equation" <| selectedShapeFeatureToValEquation selectedShapeFeature shapeTree widgets Dict.empty in
      -- Try to interpret as point?
      case rest |> Utils.findFirst (\otherSelectedShapeFeature -> selectedShapeFeaturesAreXYPairs selectedShapeFeature otherSelectedShapeFeature) of
        Just otherSelectedShapeFeature ->
          let otherEIdSets = featureValEquationToEIdSets expFilter <| Utils.fromJust_ "selectedFeaturesToEIdLists2: can't make feature into val equation" <| selectedShapeFeatureToValEquation otherSelectedShapeFeature shapeTree widgets Dict.empty in
          let singletonEIdSets      = eidSets      |> List.filter (Set.size >> (==) 1) in
          let singletonOtherEIdSets = otherEIdSets |> List.filter (Set.size >> (==) 1) in
          let pointTuples =
            Utils.cartProd singletonEIdSets singletonOtherEIdSets
            |> List.filterMap
                (\(eidSingleton, otherEIdSingleton) ->
                  case ( parentByEId program (Utils.unwrapSingletonSet eidSingleton)
                       , parentByEId program (Utils.unwrapSingletonSet otherEIdSingleton) ) of
                    (Just (Just parent), Just (Just otherParent)) ->
                      if isPair parent && parent == otherParent
                      then Just parent.val.eid
                      else Nothing

                    _ -> Nothing
                )
          in
          case pointTuples of
            []   -> eidSets :: recurse rest
            _::_ -> List.map Set.singleton pointTuples :: recurse (Utils.removeAsSet otherSelectedShapeFeature rest)

        Nothing ->
          eidSets :: recurse rest


selectedShapesToProximalDistalEIdInterpretations : Exp -> RootedIndexedTree -> List NodeId -> (Exp -> Bool) -> (Set EId, Set EId)
selectedShapesToProximalDistalEIdInterpretations program ((rootI, shapeTree) as slate) selectedShapes expFilter =
  let (proximalEIdSets, distalEIdSets) =
    selectedShapes
    |> List.map
        (\nodeId ->
          selectedShapeToValEquation nodeId shapeTree
          |> Utils.fromJust_ "selectedShapesToProximalDistalEIdInterpretations: can't make shape into val equation"
          |> featureValEquationToProximalDistalEIdSets expFilter
        )
    |> List.unzip
  in
  ( Utils.unionAll proximalEIdSets
  , Utils.unionAll distalEIdSets
  )


selectedShapesValTrees : RootedIndexedTree -> List NodeId -> List Val
selectedShapesValTrees ((rootI, shapeTree) as slate) selectedShapes =
  selectedShapes
  |> List.map
      (\nodeId ->
        selectedShapeToValEquation nodeId shapeTree
        |> Utils.fromJust_ "selectedShapesToEIdInterpretationLists: can't make shape into val equation"
        |> featureValEquationToValTree
      )


-- Combinatorical explosion of interpretations.
selectedShapesToEIdInterpretationLists : Exp -> RootedIndexedTree -> Widgets -> List NodeId -> (Exp -> Bool) -> List (List (Set EId))
selectedShapesToEIdInterpretationLists program ((rootI, shapeTree) as slate) widgets selectedShapes expFilter =
  selectedShapes
  |> List.map
      (\nodeId ->
        selectedShapeToValEquation nodeId shapeTree
        |> Utils.fromJust_ "selectedShapesToEIdInterpretationLists: can't make shape into val equation"
        |> featureValEquationToEIdSets expFilter
      )


selectedBlobsToProximalDistalEIdInterpretations : Exp -> RootedIndexedTree -> List (Int, NodeId) -> (Exp -> Bool) -> (Set EId, Set EId)
selectedBlobsToProximalDistalEIdInterpretations program ((rootI, shapeTree) as slate) selectedBlobs expFilter =
  (Set.empty, Set.empty) -- blobs will go away sometime


selectedBlobsValTrees : RootedIndexedTree -> List (Int, NodeId) -> List Val
selectedBlobsValTrees ((rootI, shapeTree) as slate) selectedBlobs =
  [] -- blobs will go away sometime


-- Unused. Combinatorical explosion of interpretations.
selectedBlobsToEIdInterpretationLists : Exp -> RootedIndexedTree -> Widgets -> List (Int, NodeId) -> (Exp -> Bool) -> List (List (Set EId))
selectedBlobsToEIdInterpretationLists program ((rootI, shapeTree) as slate) widgets selectedBlobs expFilter =
  selectedBlobs
  |> List.map (always []) -- blobs will go away sometime

