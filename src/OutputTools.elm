module OutputTools exposing
  ( OutputToolKind(..)
  , OutputTool
  , tools
  )

import Set exposing (Set)
import Dict exposing (Dict)

import FocusedEditingContext
import InterfaceModel exposing (..)
import InterfaceController as Controller
import Lang
import LangTools
import LangSvg exposing (NodeId)
import FindRepeatTools
import Provenance
import ShapeWidgets exposing (SelectableFeature(..), ShapeFeature(..), DistanceFeature(..))
import ValWidgets
import Syntax
import Utils


--==============================================================================
--= Data Types
--==============================================================================

type alias Selections a =
  { a | selectedFeatures : Set SelectableFeature
      , selectedShapes : Set NodeId
      , selectedBlobs : Dict Int NodeId
      , synthesisResultsDict : Dict String (List SynthesisResult)
  }

type OutputToolKind
  = Single
  | Multi

type alias OutputTransformation =
  Msg

type alias OutputTool =
  { name : String
  , shortcut : Maybe String
  , kind : OutputToolKind
  , func : Maybe OutputTransformation
  , reqs : List Predicate
  , id : String
  }

--==============================================================================
--= Requirement Helpers
--==============================================================================

nOrMore : Int -> Set a -> PredicateValue
nOrMore n xs =
  if Set.size xs >= n then
    Satisfied
  else
    Possible

atLeastOneFeature : Set SelectableFeature -> Predicate
atLeastOneFeature selectedFeatures =
  { description =
      "Select at least on feature"
  , value =
      nOrMore 1 selectedFeatures
  }

atLeastTwoFeatures : Set SelectableFeature -> Predicate
atLeastTwoFeatures selectedFeatures =
  { description =
      "Select at least two features"
  , value =
      nOrMore 2 selectedFeatures
  }

atLeastOneSelection : Selections a -> Predicate
atLeastOneSelection { selectedFeatures, selectedShapes, selectedBlobs } =
  let
    atLeastOneFeature =
      not <| Set.isEmpty selectedFeatures
    atLeastOneShape =
      not <| Set.isEmpty selectedShapes
    atLeastOneBlob =
      not <| Dict.isEmpty selectedBlobs
  in
    { description =
        "Select at least one feature, shape, or blob"
    , value =
        if atLeastOneFeature || atLeastOneShape || atLeastOneBlob then
          Satisfied
        else
          Possible
    }


atLeastTwoSelections : Selections a -> Predicate
atLeastTwoSelections { selectedFeatures, selectedShapes, selectedBlobs } =
  { description =
      "Select at least two features, shapes, or blobs"
  , value =
      if Set.size selectedFeatures + Set.size selectedShapes + Dict.size selectedBlobs >= 2 then
        Satisfied
      else
        Possible
  }


atLeastOneShapeNoFeatures : Selections a -> Predicate
atLeastOneShapeNoFeatures { selectedFeatures, selectedShapes, selectedBlobs } =
  let
    atLeastOneFeature =
      not <| Set.isEmpty selectedFeatures
    atLeastOneShape =
      not <| Set.isEmpty selectedShapes
    atLeastOneBlob =
      not <| Dict.isEmpty selectedBlobs
  in
    { description =
        "Select at least one shape or blob (and no features)"
    , value =
        if atLeastOneFeature then
          Impossible
        else if atLeastOneShape || atLeastOneBlob then
          Satisfied
        else
          Possible
    }

resultsCached : Selections a -> String -> Predicate
resultsCached { synthesisResultsDict } resultsKey =
  { description =
      "You shouldn't see this description. (" ++ resultsKey ++ ")"
  , value =
      if Dict.member resultsKey synthesisResultsDict then
        Satisfied
      else
        Impossible
  }

--==============================================================================
--= Tools
--==============================================================================

--------------------------------------------------------------------------------
-- Hide Widget
--------------------------------------------------------------------------------

-- Only shows tool for offsets for now, but tool should be able to handle others.
hideWidgetTool : Selections a -> OutputTool
hideWidgetTool { selectedFeatures, selectedShapes, selectedBlobs } =
  let onlyOffsetsSelected =
    let
      allSelectedFeaturesAreOffsets =
        selectedFeatures
        |> Set.toList
        |> List.all
            (\feature ->
              case feature of
                ShapeFeature idAsShape (DFeat Offset) -> idAsShape < -2 -- Offset widget selected
                _                                     -> False
            )
    in
    { description =
        "Select at least one offset widget"
    , value =
        if Set.size selectedFeatures > 0 && allSelectedFeaturesAreOffsets && Set.size selectedShapes == 0 && Dict.size selectedBlobs == 0 then
          Satisfied
        else
          Impossible
    }
  in
  { name =
      "Hide Widget" ++ if Set.size selectedFeatures >= 2 then "s" else ""
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just Controller.msgHideWidgets
  , reqs =
      [ onlyOffsetsSelected
      ]
  , id =
      "hideWidget"
  }

--------------------------------------------------------------------------------
-- Add to Output
--------------------------------------------------------------------------------

addToOutputTool : Selections a -> OutputTool
addToOutputTool selections =
  { name =
      "Add to Output"
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just Controller.msgAddToOutput
  , reqs =
      [ atLeastOneSelection selections
      ]
  , id =
      "addToOutput"
  }

--------------------------------------------------------------------------------
-- Choose Termination Condition
--------------------------------------------------------------------------------

chooseTerminationConditionTool : Selections a -> OutputTool
chooseTerminationConditionTool selections =
  let name = "Termination Condition Options" in
  { name =
      name
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgNoop
  , reqs =
      [ resultsCached selections name
      ]
  , id =
      "terminationConditionOptions"
  }

--------------------------------------------------------------------------------
-- Add Argument
--------------------------------------------------------------------------------

perhapsAddArgumentTool : Model -> List (Selections a -> OutputTool)
perhapsAddArgumentTool model =
  case FocusedEditingContext.maybeFocusedExp model.editingContext model.inputExp of
    Just focusedExp ->
      if Lang.isFunc focusedExp then
        [ \{ selectedFeatures } ->
          let name = "Add Argument" in
          { name =
              name
          , shortcut =
              Nothing
          , kind =
              Multi
          , func =
              Just Controller.msgAddArg
          , reqs =
              [ atLeastOneFeature selectedFeatures
              ]
          , id =
              "addArgument"
          }
        ]
      else
        []

    Nothing ->
      []

--------------------------------------------------------------------------------
-- Reorder in List
--------------------------------------------------------------------------------

reorderInListTool : Selections a -> OutputTool
reorderInListTool selections =
  { name =
      "Reorder in List"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgReorderInList
  , reqs =
      [ atLeastOneSelection selections
      ]
  , id =
      "reorderInList"
  }

--------------------------------------------------------------------------------
-- Dig Hole
--------------------------------------------------------------------------------

digHoleTool : Selections a -> OutputTool
digHoleTool { selectedFeatures } =
  { name =
      "Dig Hole"
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just Controller.msgDigHole
  , reqs =
      [ atLeastOneFeature selectedFeatures
      ]
  , id =
      "digHole"
  }

--------------------------------------------------------------------------------
-- Make Equal
--------------------------------------------------------------------------------

makeEqualTool : Selections a -> OutputTool
makeEqualTool { selectedFeatures } =
  { name =
      "Make Equal"
  , shortcut =
      Just "E"
  , kind =
      Multi
  , func =
      Just Controller.msgMakeEqual
  , reqs =
      [ atLeastTwoFeatures selectedFeatures
      ]
  , id =
      "makeEqual"
  }

--------------------------------------------------------------------------------
-- Relate
--------------------------------------------------------------------------------

relateTool : Selections a -> OutputTool
relateTool { selectedFeatures } =
  { name =
      "Relate"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgRelate
  , reqs =
      [ atLeastTwoFeatures selectedFeatures
      ]
  , id =
      "relate"
  }

--------------------------------------------------------------------------------
-- Indexed Relate
--------------------------------------------------------------------------------

indexedRelateTool : Selections a -> OutputTool
indexedRelateTool { selectedFeatures } =
  { name =
      "Indexed Relate"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgIndexedRelate
  , reqs =
      [ atLeastTwoFeatures selectedFeatures
      ]
  , id =
      "indexedRelate"
  }

--------------------------------------------------------------------------------
-- Abstract
--------------------------------------------------------------------------------

abstractTool : Selections a -> OutputTool
abstractTool selections =
  { name =
      "Abstract"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgAbstract
  , reqs =
      [ atLeastOneSelection selections
      ]
  , id =
      "abstract"
  }

--------------------------------------------------------------------------------
-- Dupe
--------------------------------------------------------------------------------

dupeTool : Selections a -> OutputTool
dupeTool selections =
  { name =
      "Dupe"
  , shortcut =
      Just "D"
  , kind =
      Single
  , func =
      Just Controller.msgDuplicate
  , reqs =
      [ atLeastOneSelection selections
      ]
  , id =
      "dupe"
  }

--------------------------------------------------------------------------------
-- Merge
--------------------------------------------------------------------------------

mergeTool : Selections a -> OutputTool
mergeTool selections =
  { name =
      "Merge"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgMerge
  , reqs =
      [ atLeastTwoSelections selections
      ]
  , id =
      "merge"
  }

--------------------------------------------------------------------------------
-- Group
--------------------------------------------------------------------------------

groupTool : Selections a -> OutputTool
groupTool selections =
  { name =
      "Group"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgGroup
  , reqs =
      [ atLeastTwoSelections selections
      ]
  , id =
      "group"
  }

--------------------------------------------------------------------------------
-- Fill PBE Holes Tools
--------------------------------------------------------------------------------

fillPBEHoleTools : Model -> List (Selections a -> OutputTool)
fillPBEHoleTools model =
  model.inputExp
  |> Lang.flattenExpTree
  |> List.filter Lang.isPBEHole
  |> Utils.mapi1
      (\(i, pbeHoleExp) ->
        (\selections ->
          let name =
            -- Name is also used as synthesisResultsDict key, so include an index i to avoid collisions.
            "Fill Hole " ++ toString i ++ " (" ++ LangTools.expNameForEId model.inputExp pbeHoleExp.val.eid ++ ")"
          in
          { name = name
          , shortcut = Nothing
          , kind = Multi
          , func = Just (Controller.msgFillPBEHole pbeHoleExp.val.eid name)
          , reqs = []
          , id = "fillPBEHole" ++ toString i
          }
        )
      )

--------------------------------------------------------------------------------
-- Repeat by Indexed Merge Tool
--------------------------------------------------------------------------------

repeatByIndexedMergeTool : Selections a -> OutputTool
repeatByIndexedMergeTool selections =
  { name =
      "Repeat by Indexed Merge"
  , shortcut =
      Nothing
  , kind =
      Multi
  , func =
      Just Controller.msgRepeatByIndexedMerge
  , reqs =
      [ atLeastTwoSelections selections
      ]
  , id =
      "merge"
  }

--------------------------------------------------------------------------------
-- User/prelude-defined Repeat Functions
--------------------------------------------------------------------------------

functionBasedRepeatTools : Model -> List (Selections a -> OutputTool)
functionBasedRepeatTools model =
  FindRepeatTools.getRepetitionFunctions -- Returns list of (fName, fExp, typeSig), fExp is an EFun
      model.inputExp
      model.idToTypeAndContextThunk
      model.editingContext
  |> List.map
      (\(funcName, _) ->
        (\selections ->
          let name = "Repeat With Function " ++ funcName in
          { name = name
          , shortcut = Nothing
          , kind = Multi
          , func = Just (Controller.msgRepeatUsingFunction funcName name)
          , reqs = [ atLeastOneSelection selections ]
          , id = funcName
          }
        )
      )


pointListBasedRepeatTools : Model -> List (Selections a -> OutputTool)
pointListBasedRepeatTools model =
  model.widgets
  |> List.filterMap ValWidgets.widgetToMaybeVal
  |> List.filter (Lang.vListToMaybePointVals >> Maybe.withDefault [] >> (/=) []) -- Empty lists pass vListToMaybePointVals but we want them excluded.
  |> Utils.dedupBy Lang.valEId -- Avoid showing same list multiple times.
  |> Utils.mapi1
      (\(i, pointListVal) ->
        (\selections ->
          let name =
            -- Name is also used as synthesisResultsDict key, so include an index i to avoid collisions.
            "Repeat Over List " ++ toString i ++ ": " ++
                case LangTools.findLetAndIdentBindingExpLoose (Lang.valEId pointListVal) model.inputExp of
                  Just (_, ident) -> ident
                  Nothing         -> Utils.squish (Syntax.unparser Syntax.Elm (Lang.valExp pointListVal))
          in
          { name = name
          , shortcut = Nothing
          , kind = Multi
          , func = Just (Controller.msgRepeatUsingPointList pointListVal name)
          , reqs = [ atLeastOneSelection selections ]
          , id = "repeatOverList" ++ toString i
          }
        )
      )


--------------------------------------------------------------------------------
-- Repeat Right
--------------------------------------------------------------------------------

repeatRightTool : Selections a -> OutputTool
repeatRightTool selections =
  { name =
      "Repeat Right"
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just <| Controller.msgReplicateBlob HorizontalRepeat
  , reqs =
      [ atLeastOneShapeNoFeatures selections
      ]
  , id =
      "repeateRight"
  }

--------------------------------------------------------------------------------
-- Repeat To
--------------------------------------------------------------------------------

repeatToTool : Selections a -> OutputTool
repeatToTool selections =
  { name =
      "Repeat To"
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just <| Controller.msgReplicateBlob LinearRepeat
  , reqs =
      [ atLeastOneShapeNoFeatures selections
      ]
  , id =
      "repeateTo"
  }

--------------------------------------------------------------------------------
-- Repeat Around
--------------------------------------------------------------------------------

repeatAroundTool : Selections a -> OutputTool
repeatAroundTool selections =
  { name =
      "Repeat Around"
  , shortcut =
      Nothing
  , kind =
      Single
  , func =
      Just <| Controller.msgReplicateBlob RadialRepeat
  , reqs =
      [ atLeastOneShapeNoFeatures selections
      ]
  , id =
      "repeateAround"
  }

--------------------------------------------------------------------------------
-- All Tools
--------------------------------------------------------------------------------

tools : Model -> List (List OutputTool)
tools model =
  List.map (List.map <| \tool -> tool model) <|
    [ [ hideWidgetTool
      , addToOutputTool
      , chooseTerminationConditionTool
      ]
    , perhapsAddArgumentTool model
    , [ reorderInListTool ]
    , -- [ digHoleTool
      [ makeEqualTool
      , relateTool
      -- , indexedRelateTool
      ]
    , [ dupeTool
      , mergeTool
      , groupTool
      , abstractTool
      ]
    , fillPBEHoleTools model
    , [ repeatByIndexedMergeTool ]
    , pointListBasedRepeatTools model
    , functionBasedRepeatTools model
    , [ repeatRightTool
      , repeatToTool
      , repeatAroundTool
      ]
    ]
