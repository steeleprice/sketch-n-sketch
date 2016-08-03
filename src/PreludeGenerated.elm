module PreludeGenerated (src) where

prelude =
 "
; prelude.little
;
; This little library is accessible by every program.
; This is not an example that generates an SVG canvas,
; but we include it here for reference.

;; The identity function - given a value, returns exactly that value
(typ id (-> a a))
(def id (\\x x))

;; A function that always returns the same value a, regardless of b
(typ always (-> a b a))
(def always (\\(x _) x))

;; Composes two functions together
(typ compose (-> (-> a b) (-> b c) (-> a c)))
(def compose (\\(f g) (\\x (f (g x)))))

(typ flip (-> (-> a b c) (-> b a c)))
(def flip (\\(f x y) (f y x)))

;; Returns the first element of a given list
(typ fst (-> (List a) a))
(def fst (\\[x|_] x))

(typ snd (-> (List a) a))
(def snd (\\[_ y|_] y))

;; Returns the length of a given list
(typ len (-> (List a) Num))
(defrec len (\\xs (case xs ([] 0) ([_ | xs1] (+ 1 (len xs1))))))

;; Maps a function, f, over a list of values and returns the resulting list
(typ map (-> (-> a b) (List a) (List b)))
(defrec map (\\(f xs)
  (case xs ([] []) ([hd|tl] [(f hd)|(map f tl)]))))

;; Combines two lists with a given function, extra elements are dropped
(typ map2 (-> (-> a b c) (List a) (List b) (List c)))
(defrec map2 (\\(f xs ys)
  (case [xs ys]
    ([[x|xs1] [y|ys1]] [ (f x y) | (map2 f xs1 ys1) ])
    (_                 []))))

;; Takes a function, an accumulator, and a list as input and reduces using the function from the left
(typ foldl (-> (-> a b b) b (List a) b))
(defrec foldl (\\(f acc xs)
  (case xs ([] acc) ([x|xs1] (foldl f (f x acc) xs1)))))

;; Takes a function, an accumulator, and a list as input and reduces using the function from the right
(typ foldr (-> (-> a b b) b (List a) b))
(defrec foldr (\\(f acc xs)
  (case xs ([] acc) ([x|xs1] (f x (foldr f acc xs1))))))

;; Given two lists, append the second list to the end of the first
(typ append (-> (List a) (List a) (List a)))
(defrec append (\\(xs ys)
  (case xs ([] ys) ([x|xs1] [ x | (append xs1 ys)]))))

;; concatenate a list of lists into a single list
(typ concat (-> (List (List a)) (List a)))
(def concat (foldr append []))

;; Map a given function over a list and concatenate the resulting list of lists
(typ concatMap (-> (-> a (List b)) (List a) (List b)))
(def concatMap (\\(f xs) (concat (map f xs))))

;; Takes two lists and returns a list that is their cartesian product
(typ cartProd (-> (List a) (List b) (List [a b])))
(def cartProd (\\(xs ys)
  (concatMap (\\x (map (\\y [x y]) ys)) xs)))

;; Takes elements at the same position from two input lists and returns a list of pairs of these elements
(typ zip (-> (List a) (List b) (List [a b])))
(def zip (map2 (\\(x y) [x y])))

;; The empty list
(typ nil (List a))
(def nil  [])

;; attaches an element to the front of a list
(typ cons (-> a (List a) (List a)))
(def cons (\\(x xs) [x | xs]))

;; attaches an element to the end of a list
(typ snoc (-> a (List a) (List a)))
(def snoc (\\(x ys) (append ys [x])))

;; Returns the first element of a given list
(typ hd (-> (List a) a))
(def hd   (\\[x|xs] x))

;; Returns the last element of a given list
(typ tl (-> (List a) a))
(def tl   (\\[x|xs] xs))

;; Given a list, reverse its order
(typ reverse (-> (List a) (List a)))
(def reverse (foldl cons nil))

;; Given two numbers, creates the list between them (inclusive)
(typ range (-> Num Num (List Num)))
(defrec range (\\(i j)
  (if (< i (+ j 1))
      (cons i (range (+ i 1) j))
      nil)))

;; Given a number, create the list of 0 to that number inclusive (number must be > 0)
(typ list0N (-> Num (List Num)))
(def list0N (\\n (range 0 n)))

;; Given a number, create the list of 1 to that number inclusive
(typ list1N (-> Num (List Num)))
(def list1N (\\n (range 1 n)))

(typ zeroTo (-> Num (List Num)))
(def zeroTo (\\n (range 0 (- n 1))))

;; Given a number n and some value x, return a list with x repeated n times
(typ repeat (-> Num a (List a)))
(def repeat (\\(n x) (map (always x) (range 1 n))))

;; Given two lists, return a single list that alternates between their values (first element is from first list)
(typ intermingle (-> (List a) (List a) (List a)))
(defrec intermingle (\\(xs ys)
  (case [xs ys]
    ([[x|xs1] [y|ys1]] (cons x (cons y (intermingle xs1 ys1))))
    ([[]      []]      nil)
    (_                 (append xs ys)))))

(typ mapi (-> (-> [Num a] b) (List a) (List b)))
(def mapi (\\(f xs) (map f (zip (range 0 (- (len xs) 1)) xs))))

(typ nth (-> (List a) Num a))
(defrec nth (\\(xs n)
  (if (< n 0)       'ERROR: nth'
    (case [n xs]
      ([_ []]       'ERROR: nth')
      ([0 [x|xs1]]  x)
      ([_ [x|xs1]]  (nth xs1 (- n 1)))))))
; (defrec nth (\\(xs n)
;   (if (< n 0)   'ERROR: nth'
;     (case xs
;       ([]       'ERROR: nth')
;       ([x|xs1]  (if (= n 0) x (nth xs1 (- n 1))))))))

(typ take (-> (List a) Num (List a)))
(defrec take (\\(xs n)
  (if (= n 0) []
    (case xs
      ([]      'ERROR: take')
      ([x|xs1] [x | (take xs1 (- n 1))])))))
; (def take
;   (letrec take_ (\\(n xs)
;     (case [n xs]
;       ([0 _]       [])
;       ([_ []]      [])
;       ([_ [x|xs1]] [x | (take_ (- n 1) xs1)])))
;   (compose take_ (max 0))))

(typ elem (-> a (List a) Bool))
(defrec elem (\\(x ys)
  (case ys
    ([]      false)
    ([y|ys1] (or (= x y) (elem x ys1))))))


;; multiply two numbers and return the result
(typ mult (-> Num Num Num))
(defrec mult (\\(m n)
  (if (< m 1) 0 (+ n (mult (+ m -1) n)))))

;; Given two numbers, subtract the second from the first
(typ minus (-> Num Num Num))
(def minus (\\(x y) (+ x (mult y -1))))

;; Given two numbers, divide the first by the second
(typ div (-> Num Num Num))
(defrec div (\\(m n)
  (if (< m n) 0
  (if (< n 2) m
    (+ 1 (div (minus m n) n))))))

;; Given a number, returns the negative of that number
(typ neg (-> Num Num))
(def neg (\\x (- 0 x)))

;; Given a bool, returns the opposite boolean value
(typ not (-> Bool Bool))
(def not (\\b (if b false true)))

;; Given two bools, returns a bool regarding if the first argument is true, then the second argument is as well
(typ implies (-> Bool Bool Bool))
(def implies (\\(p q) (if p q true)))

(typ or  (-> Bool Bool Bool))
(typ and (-> Bool Bool Bool))

(def or  (\\(p q) (if p true q)))
(def and (\\(p q) (if p q false)))

(typ some (-> (-> a Bool) (List a) Bool))
(defrec some (\\(p xs)
  (case xs
    ([]      false)
    ([x|xs1] (or (p x) (some p xs1))))))

(typ all (-> (-> a Bool) (List a) Bool))
(defrec all (\\(p xs)
  (case xs
    ([]      true)
    ([x|xs1] (and (p x) (all p xs1))))))

;; Given an upper bound, lower bound, and a number, restricts that number between those bounds (inclusive)
;; Ex. clamp 1 5 4 = 4
;; Ex. clamp 1 5 6 = 5
(typ clamp (-> Num Num Num Num))
(def clamp (\\(i j n) (if (< n i) i (if (< j n) j n))))

(typ between (-> Num Num Num Bool))
(def between (\\(i j n) (= n (clamp i j n))))

(typ lt (-> Num Num Bool))
(typ eq (-> Num Num Bool))
(typ le (-> Num Num Bool))
(typ gt (-> Num Num Bool))
(typ ge (-> Num Num Bool))

(def lt (\\(x y) (< x y)))
(def eq (\\(x y) (= x y)))
(def le (\\(x y) (or (lt x y) (eq x y))))
(def gt (flip lt))
(def ge (\\(x y) (or (gt x y) (eq x y))))

(typ plus (-> Num Num Num))
(def plus (\\(x y) (+ x y)))

(typ min (-> Num Num Num))
(def min (\\(i j) (if (lt i j) i j)))

(typ max (-> Num Num Num))
(def max (\\(i j) (if (gt i j) i j)))

(typ minimum (-> (List Num) Num))
(def minimum (\\[hd|tl] (foldl min hd tl)))

(typ maximum (-> (List Num) Num))
(def maximum (\\[hd|tl] (foldl max hd tl)))

(typ average (-> (List Num) Num))
(def average (\\nums
  (let sum (foldl plus 0 nums)
  (let n   (len nums)
    (/ sum n)))))

;; Combine a list of strings with a given separator
;; Ex. joinStrings ', ' ['hello' 'world'] = 'hello, world'
(typ joinStrings (-> String (List String) String))
(def joinStrings (\\(sep ss)
  (foldr (\\(str acc) (if (= acc '') str (+ str (+ sep acc)))) '' ss)))

;; Concatenate a list of strings and return the resulting string
(typ concatStrings (-> (List String) String))
(def concatStrings (joinStrings ''))

;; Concatenates a list of strings, interspersing a single space in between each string
(typ spaces (-> (List String) String))
(def spaces (joinStrings ' '))

;; First two arguments are appended at the front and then end of the third argument correspondingly
;; Ex. delimit '+' '+' 'plus' = '+plus+'
(typ delimit (-> String String String String))
(def delimit (\\(a b s) (concatStrings [a s b])))

;; delimit a string with parentheses
(typ parens (-> String String))
(def parens (delimit '(' ')'))

;
; SVG Manipulating Functions
;

;; argument order - color, x, y, radius
;; creates a circle, center at (x,y) with given radius and color
(typ circle (-> String Num Num Num svg))
(def circle (\\(fill x y r)
  ['circle'
     [['cx' x] ['cy' y] ['r' r] ['fill' fill]]
     []]))

;; argument order - color, width, x, y, radius
;; Just as circle, except new width parameter determines thickness of ring
(typ ring (-> String Num Num Num Num svg))
(def ring (\\(c w x y r)
  ['circle'
     [ ['cx' x] ['cy' y] ['r' r] ['fill' 'none'] ['stroke' c] ['stroke-width' w] ]
     []]))

;; argument order - color, x, y, x-radius, y-radius
;; Just as circle, except radius is separated into x and y parameters
(typ ellipse (-> String Num Num Num Num svg))
(def ellipse (\\(fill x y rx ry)
  ['ellipse'
     [ ['cx' x] ['cy' y] ['rx' rx] ['ry' ry] ['fill' fill] ]
     []]))

;; argument order - color, x, y, width, height
;; creates a rectangle of given width and height with (x,y) as the top left corner coordinate
(typ rect (-> String Num Num Num Num svg))
(def rect (\\(fill x y w h)
  ['rect'
     [ ['x' x] ['y' y] ['width' w] ['height' h] ['fill' fill] ]
     []]))

(typ square (-> String Num Num Num svg))
(def square (\\(fill x y side) (rect fill x y side side)))

;; argument order - color, width, x1, y1, x1, y2
;; creates a line from (x1, y1) to (x2,y2) with given color and width
(typ line (-> String Num Num Num Num Num svg))
(def line (\\(fill w x1 y1 x2 y2)
  ['line'
     [ ['x1' x1] ['y1' y1] ['x2' x2] ['y2' y2] ['stroke' fill] ['stroke-width' w] ]
     []]))

;; argument order - fill, stroke, width, points
;; creates a polygon following the list of points, with given fill color and a border with given width and stroke
(typ polygon (-> String String Num (List (List Num)) svg))
(def polygon (\\(fill stroke w pts)
  ['polygon'
     [ ['fill' fill] ['points' pts] ['stroke' stroke] ['stroke-width' w] ]
     []]))

;; argument order - fill, stroke, width, points
;; See polygon
(typ polyline (-> String String Num (List (List Num)) svg))
(def polyline (\\(fill stroke w pts)
  ['polyline'
     [ ['fill' fill] ['points' pts] ['stroke' stroke] ['stroke-width' w] ]
     []]))

;; argument order - fill, stroke, width, d
;; Given SVG path command d, create path with given fill color, stroke and width
;; See https://developer.mozilla.org/en-US/docs/Web/SVG/Tutorial/Paths for path command info
(typ path (-> String String Num (List a) svg))
(def path (\\(fill stroke w d)
  ['path'
     [ ['fill' fill] ['stroke' stroke] ['stroke-width' w] ['d' d] ]
     []]))

;; argument order - x, y, string
;; place a text string with top left corner at (x,y) - with default color & font
(typ text (-> Num Num String svg))
(def text (\\(x y s)
   ['text' [['x' x] ['y' y] ['style' 'fill:black']
            ['font-family' 'Tahoma, sans-serif']]
           [['TEXT' s]]]))

;; argument order - shape, new attribute
;; Add a new attribute to a given Shape
(typ addAttr (-> svg attr svg))
(def addAttr (\\([shapeKind oldAttrs children] newAttr)
  [shapeKind (snoc newAttr oldAttrs) children]))

(typ consAttr (-> svg attr svg))
(def consAttr (\\([shapeKind oldAttrs children] newAttr)
  [shapeKind (cons newAttr oldAttrs) children]))

;; Given a list of shapes, compose into a single SVG
(def svg (\\shapes ['svg' [] shapes]))

;; argument order - x-maximum, y-maximum, shapes
;; Given a list of shapes, compose into a single SVG within the x & y maxima
(typ svgViewBox (-> Num Num (List svg) svg))
(def svgViewBox (\\(xMax yMax shapes)
  (let [sx sy] [(toString xMax) (toString yMax)]
  ['svg'
    [['x' '0'] ['y' '0'] ['viewBox' (joinStrings ' ' ['0' '0' sx sy])]]
    shapes])))

;; As rect, except x & y represent the center of the defined rectangle
(typ rectCenter (-> String Num Num Num Num svg))
(def rectCenter (\\(fill cx cy w h)
  (rect fill (- cx (/ w 2)) (- cy (/ h 2)) w h)))

;; As square, except x & y represent the center of the defined rectangle
(typ squareCenter (-> String Num Num Num svg))
(def squareCenter (\\(fill cx cy w) (rectCenter fill cx cy w w)))

;; Some shapes with given default values for fill, stroke, and stroke width
; TODO remove these
(def circle_    (circle 'red'))
(def ellipse_   (ellipse 'orange'))
(def rect_      (rect '#999999'))
(def square_    (square '#999999'))
(def line_      (line 'blue' 2))
(def polygon_   (polygon 'green' 'purple' 3))
(def path_      (path 'transparent' 'goldenrod' 5))

;; updates an SVG by comparing differences with another SVG
;; Note: accDiff pre-condition: indices in increasing order
;; (so can't just use foldr instead of reverse . foldl)
(typ updateCanvas (-> svg svg svg))
(def updateCanvas (\\([_ svgAttrs oldShapes] diff)
  (let oldShapesI (zip (list1N (len oldShapes)) oldShapes)
  (let initAcc [[] diff]
  (let f (\\([i oldShape] [accShapes accDiff])
    (case accDiff
      ([]
        [(cons oldShape accShapes) accDiff])
      ([[j newShape] | accDiffRest]
        (if (= i j)
          [(cons newShape accShapes) accDiffRest]
          [(cons oldShape accShapes) accDiff]))))
  (let newShapes (reverse (fst (foldl f initAcc oldShapesI)))
    ['svg' svgAttrs newShapes]))))))

(typ addShapeToCanvas (-> svg svg svg))
(def addShapeToCanvas (\\(['svg' svgAttrs oldShapes] newShape)
  ['svg' svgAttrs (append oldShapes [newShape])]))

(typ addShape (-> svg svg svg))
(def addShape (flip addShapeToCanvas))

(typ groupMap (-> (List a) (-> a b) (List b)))
(def groupMap (\\(xs f) (map f xs)))

(def autoChose (\\(_ x _) x))
(def inferred  (\\(x _ _) x))
(def flow (\\(_ x) x))

(typ lookupWithDefault (-> v k (List [k v]) v))
(defrec lookupWithDefault (\\(default k dict)
  (let foo (lookupWithDefault default k)
  (case dict
    ([]            default)
    ([[k1 v]|rest] (if (= k k1) v (foo rest)))))))

(typ lookup (-> k (List [k v]) v))
(defrec lookup (\\(k dict)
  (let foo (lookup k)
  (case dict
    ([]            'NOTFOUND')
    ([[k1 v]|rest] (if (= k k1) v (foo rest)))))))

(defrec addExtras (\\(i extras shape)
  (case extras
    ([] shape)
    ([[k table] | rest]
      (let v (lookup i table)
      (if (= v 'NOTFOUND')
          (addExtras i rest shape)
          (addExtras i rest (addAttr shape [k v]))))))))

(typ lookupAttr (-> svg attrName attrVal))
(def lookupAttr (\\([_ attrs _] k) (lookup k attrs)))

; \"constant folding\"
(def twoPi (* 2 (pi)))
(def halfPi (/ (pi) 2))

;; Helper function for nPointsOnCircle, calculates angle of points
;; Note: angles are calculated clockwise from the traditional pi/2 mark
(typ nPointsOnUnitCircle (-> Num Num (List Num)))
(def nPointsOnUnitCircle (\\(n rot)
  (let off (- halfPi rot)
  (let foo (\\i
    (let ang (+ off (* (/ i n) twoPi))
    [(cos ang) (neg (sin ang))]))
  (map foo (list0N (- n 1)))))))

(typ nPointsOnCircle (-> Num Num Num Num Num (List Num)))
;; argument order - Num of points, degree of rotation, x-center, y-center, radius
;; Scales nPointsOnUnitCircle to the proper size and location with a given radius and center
(def nPointsOnCircle (\\(n rot cx cy r)
  (let pts (nPointsOnUnitCircle n rot)
  (map (\\[x y] [(+ cx (* x r)) (+ cy (* y r))]) pts))))

(typ nStar (-> color color Num Num Num Num Num Num Num svg))
;; argument order -
;; fill color - interior color of star
;; stroke color - border color of star
;; width - thickness of stroke
;; points - number of star points
;; len1 - length from center to one set of star points
;; len2 - length from center to other set of star points (either inner or outer compared to len1)
;; rot - degree of rotation
;; cx - x-coordinate of center position
;; cy - y-coordinate of center position
;; Creates stars that can be modified on a number of parameters
(def nStar (\\(fill stroke w n len1 len2 rot cx cy)
  (let pti (\\[i len]
    (let anglei (+ (- (/ (* i (pi)) n) rot) halfPi)
    (let xi (+ cx (* len (cos anglei)))
    (let yi (+ cy (neg (* len (sin anglei))))
      [xi yi]))))
  (let lengths
    (map (\\b (if b len1 len2))
         (concat (repeat n [true false])))
  (let indices (list0N (- (* 2! n) 1!))
    (polygon fill stroke w (map pti (zip indices lengths))))))))

(def setZones (\\(s shape) (addAttr shape ['ZONES' s])))

;; zones : String -> List Shape -> List Shape
(def zones (\\s (map (setZones s))))

;; hideZonesTail : List Shape -> List Shape
;; Remove all zones from shapes except for the first in the list
(def hideZonesTail  (\\[hd | tl] [hd | (zones 'none'  tl)]))

;; basicZonesTail : List Shape -> List Shape
;; Turn all zones to basic for a given list of shapes except for the first shape
(def basicZonesTail (\\[hd | tl] [hd | (zones 'basic' tl)]))

(def ghost
  ; consAttr (instead of addAttr) makes internal calls to
  ; Utils.maybeRemoveFirst \"HIDDEN\" slightly faster
  (\\shape (consAttr shape ['HIDDEN' ''])))

(def ghosts (map ghost))

;; hSlider_ : Bool -> Bool -> Int -> Int -> Int -> Num -> Num -> Str -> Num
;; -> [Num (List Svg)]
;; argument order - dropBall roundInt xStart xEnd y minVal maxVal caption srcVal
;; dropBall - Determines if the slider ball continues to appear past the edges of the slider
;; roundInt - Determines whether to round to Ints or not
;; xStart - left edge of slider
;; xEnd - right edge of slider
;; y - y positioning of entire slider bar
;; minVal - minimum value of slider
;; maxVal - maximum value of slider
;; caption - text to display along with the slider
;; srcVal - the current value given by the slider ball
(def hSlider_ (\\(dropBall roundInt x0 x1 y minVal maxVal caption srcVal)
  (let preVal (clamp minVal maxVal srcVal)
  (let targetVal (if roundInt (round preVal) preVal)
  (let shapes
    (let ball
      (let [xDiff valDiff] [(- x1 x0) (- maxVal minVal)]
      (let xBall (+ x0 (* xDiff (/ (- srcVal minVal) valDiff)))
      (if (= preVal srcVal) (circle 'black' xBall y 10!)
      (if dropBall          (circle 'black' 0! 0! 0!)
                            (circle 'red' xBall y 10!)))))
    [ (line 'black' 3! x0 y x1 y)
      (text (+ x1 10) (+ y 5) (+ caption (toString targetVal)))
      (circle 'black' x0 y 4!) (circle 'black' x1 y 4!) ball ])
  [targetVal (ghosts shapes)])))))
; TODO only draw zones for ball

(def vSlider_ (\\(dropBall roundInt y0 y1 x minVal maxVal caption srcVal)
  (let preVal (clamp minVal maxVal srcVal)
  (let targetVal (if roundInt (round preVal) preVal)
  (let shapes
    (let ball
      (let [yDiff valDiff] [(- y1 y0) (- maxVal minVal)]
      (let yBall (+ y0 (* yDiff (/ (- srcVal minVal) valDiff)))
      (if (= preVal srcVal) (circle 'black' x yBall 10!)
      (if dropBall          (circle 'black' 0! 0! 0!)
                            (circle 'red' x yBall 10!)))))
    [ (line 'black' 3! x y0 x y1)
      ; (text (+ x1 10) (+ y 5) (+ caption (toString targetVal)))
      (circle 'black' x y0 4!) (circle 'black' x y1 4!) ball ])
  [targetVal (ghosts shapes)])))))
; TODO only draw zones for ball

(def hSlider (hSlider_ false))
(def vSlider (vSlider_ false))

;; button_ : Bool -> Num -> Num -> String -> Num -> SVG
;; Similar to sliders, but just has boolean values
(def button_ (\\(dropBall xStart y caption xCur)
  (let [rPoint wLine rBall wSlider] [4! 3! 10! 70!]
  (let xEnd (+ xStart wSlider)
  (let xBall (+ xStart (* xCur wSlider))
  (let xBall_ (clamp xStart xEnd xBall)
  (let val (< xCur 0.5)
  (let shapes1
    [ (circle 'black' xStart y rPoint)
      (circle 'black' xEnd y rPoint)
      (line 'black' wLine xStart y xEnd y)
      (text (+ xEnd 10) (+ y 5) (+ caption (toString val))) ]
  (let shapes2
    [ (if (= xBall_ xBall) (circle (if val 'darkgreen' 'darkred') xBall y rBall)
      (if dropBall         (circle 'black' 0! 0! 0!)
                           (circle 'red' xBall y rBall))) ]
  (let shapes (append (zones 'none' shapes1) (zones 'basic' shapes2))
  [val (ghosts shapes)]))))))))))

(def button (button_ false))

(def xySlider
  (\\(xStart xEnd yStart yEnd xMin xMax yMin yMax xCaption yCaption xCur yCur)
    (let [rCorner wEdge rBall] [4! 3! 10!]
    (let [xDiff yDiff xValDiff yValDiff] [(- xEnd xStart) (- yEnd yStart) (- xMax xMin) (- yMax yMin)]
    (let xBall (+ xStart (* xDiff (/ (- xCur xMin) xValDiff)))
    (let yBall (+ yStart (* yDiff (/ (- yCur yMin) yValDiff)))
    (let cBall (if (and (between xMin xMax xCur) (between yMin yMax yCur)) 'black' 'red')
    (let xVal (ceiling (clamp xMin xMax xCur))
    (let yVal (ceiling (clamp yMin yMax yCur))
    (let myLine (\\(x1 y1 x2 y2) (line 'black' wEdge x1 y1 x2 y2))
    (let myCirc (\\(x0 y0) (circle 'black' x0 y0 rCorner))
    (let shapes
      [ (myLine xStart yStart xEnd yStart)
        (myLine xStart yStart xStart yEnd)
        (myLine xStart yEnd xEnd yEnd)
        (myLine xEnd yStart xEnd yEnd)
        (myCirc xStart yStart)
        (myCirc xStart yEnd)
        (myCirc xEnd yStart)
        (myCirc xEnd yEnd)
        (circle cBall xBall yBall rBall)
        (text (- (+ xStart (/ xDiff 2)) 40) (+ yEnd 20) (+ xCaption (toString xVal)))
        (text (+ xEnd 10) (+ yStart (/ yDiff 2)) (+ yCaption (toString yVal))) ]
    [ [ xVal yVal ] (ghosts shapes) ]
))))))))))))

(def enumSlider (\\(x0 x1 y enum caption srcVal)
  (let n (len enum)
  (let [minVal maxVal] [0! n]
  (let preVal (clamp minVal maxVal srcVal)
  (let i (floor preVal)
  (let item (nth enum i)
  (let wrap (\\circ (addAttr circ ['SELECTED' ''])) ; TODO
  (let shapes
    (let rail [ (line 'black' 3! x0 y x1 y) ]
    (let ball
      (let [xDiff valDiff] [(- x1 x0) (- maxVal minVal)]
      (let xBall (+ x0 (* xDiff (/ (- preVal minVal) valDiff)))
      (let rBall (if (= preVal srcVal) 10! 0!)
        [ (wrap (circle 'black' xBall y rBall)) ])))
    (let endpoints
      [ (wrap (circle 'black' x0 y 4!)) (wrap (circle 'black' x1 y 4!)) ]
    (let tickpoints
      (let sep (/ (- x1 x0) n)
      (map (\\j (wrap (circle 'grey' (+ x0 (mult j sep)) y 4!)))
           (range 1! (- n 1!))))
    (let label [ (text (+ x1 10!) (+ y 5!) (+ caption (toString item))) ]
    (concat [ rail endpoints tickpoints ball label ]))))))
  [item (ghosts shapes)])))))))))

(def addSelectionSliders (\\(y0 seeds shapesCaps)
  (let shapesCapsSeeds (zip shapesCaps (take seeds (len shapesCaps)))
  (let foo (\\[i [[shape cap] seed]]
    (let [k _ _] shape
    (let enum
      (if (= k 'circle') ['' 'cx' 'cy' 'r']
      (if (= k 'line')   ['' 'x1' 'y1' 'x2' 'y2']
      (if (= k 'rect')   ['' 'x' 'y' 'width' 'height']
        [(+ 'NO SELECTION ENUM FOR KIND ' k)])))
    (let [item slider] (enumSlider 20! 170! (+ y0 (mult i 30!)) enum cap seed)
    (let shape1 (addAttr shape ['SELECTED' item]) ; TODO overwrite existing
    [shape1|slider])))))
  (concat (mapi foo shapesCapsSeeds))))))


(typ rotate (-> svg Num Num Num svg))
;; argument order - shape, rot, x, y
;; Takes a shape rotates it rot degrees around point (x,y)
(def rotate (\\(shape n1 n2 n3)
  (addAttr shape ['transform' [['rotate' n1 n2 n3]]])))

(def rotateAround (\\(rot x y shape)
  (addAttr shape ['transform' [['rotate' rot x y]]])))

(typ radToDeg (-> Num Num))
(def radToDeg (\\rad (* (/ rad (pi)) 180!)))


; Polygon and Path Helpers

(def middleOfPoints (\\pts
  (let [xs ys] [(map fst pts) (map snd pts)]
  (let [xMin xMax] [(minimum xs) (maximum xs)]
  (let [yMin yMax] [(minimum ys) (maximum ys)]
  (let xMiddle (+ xMin (* 0.5 (- xMax xMin)))
  (let yMiddle (+ yMin (* 0.5 (- yMax yMin)))
    [xMiddle yMiddle] )))))))

(defrec allPointsOfPathCmds (\\cmds (case cmds
  ([]    [])
  (['Z'] [])

  (['M' x y | rest] (cons [x y] (allPointsOfPathCmds rest)))
  (['L' x y | rest] (cons [x y] (allPointsOfPathCmds rest)))

  (['Q' x1 y1 x y | rest]
    (append [[x1 y1] [x y]] (allPointsOfPathCmds rest)))

  (['C' x1 y1 x2 y2 x y | rest]
    (append [[x1 y1] [x2 y2] [x y]] (allPointsOfPathCmds rest)))

  (_ 'ERROR')
)))


; Raw Shapes

(def rawShape (\\(kind attrs) [kind attrs []]))

(def rawRect (\\(fill stroke strokeWidth x y w h rot)
  (let [cx cy] [(+ x (/ w 2!)) (+ y (/ h 2!))]
  (rotateAround rot cx cy
    (rawShape 'rect' [
      ['x' x] ['y' y] ['width' w] ['height' h]
      ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth] ])))))

(def rawCircle (\\(fill stroke strokeWidth cx cy r)
  (rawShape 'circle' [
    ['cx' cx] ['cy' cy] ['r' r]
    ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth] ])))

(def rawEllipse (\\(fill stroke strokeWidth cx cy rx ry rot)
  (rotateAround rot cx cy
    (rawShape 'ellipse' [
      ['cx' cx] ['cy' cy] ['rx' rx] ['ry' ry]
      ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth] ]))))

(def rawPolygon (\\(fill stroke w pts rot)
  (let [cx cy] (middleOfPoints pts)
  (rotateAround rot cx cy
    (rawShape 'polygon'
      [ ['fill' fill] ['points' pts] ['stroke' stroke] ['stroke-width' w] ])))))

(def rawPath (\\(fill stroke w d rot)
  (let [cx cy] (middleOfPoints (allPointsOfPathCmds d))
  (rotateAround rot cx cy
    (rawShape 'path'
      [ ['fill' fill] ['d' d] ['stroke' stroke] ['stroke-width' w] ])))))


; Shapes via Bounding Boxes

(def box (\\(bounds fill stroke strokeWidth)
  (let [x y xw yh] bounds
  ['BOX'
    [ ['LEFT' x] ['TOP' y] ['RIGHT' xw] ['BOT' yh]
      ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth]
    ] []
  ])))

; string fill/stroke/stroke-width attributes to avoid sliders
(def hiddenBoundingBox (\\bounds
  (ghost (box bounds 'transparent' 'transparent' '0'))))

(def simpleBoundingBox (\\bounds
  (ghost (box bounds 'transparent' 'darkblue' 1))))

(def strList
  (let foo (\\(x acc) (+ (+ acc (if (= acc '') '' ' ')) (toString x)))
  (foldl foo '')))

(def fancyBoundingBox (\\bounds
  (let [left top right bot] bounds
  (let [width height] [(- right left) (- bot top)]
  (let [c1 c2 r] ['darkblue' 'skyblue' 6]
  [ (ghost (box bounds 'transparent' c1 1))
    (ghost (setZones 'none' (circle c2 left top r)))
    (ghost (setZones 'none' (circle c2 right top r)))
    (ghost (setZones 'none' (circle c2 right bot r)))
    (ghost (setZones 'none' (circle c2 left bot r)))
    (ghost (setZones 'none' (circle c2 left (+ top (/ height 2)) r)))
    (ghost (setZones 'none' (circle c2 right (+ top (/ height 2)) r)))
    (ghost (setZones 'none' (circle c2 (+ left (/ width 2)) top r)))
    (ghost (setZones 'none' (circle c2 (+ left (/ width 2)) bot r)))
  ])))))

(def group (\\(bounds shapes)
  (let [left top right bot] bounds
  (let pad 15
  (let paddedBounds [(- left pad) (- top pad) (+ right pad) (+ bot pad)]
  ['g' [['BOUNDS' bounds]]
       (cons (hiddenBoundingBox paddedBounds) shapes)]
)))))

; (def group (\\(bounds shapes)
;   ['g' [['BOUNDS' bounds]]
;        (cons (hiddenBoundingBox bounds) shapes)]))

       ; (concat [(fancyBoundingBox bounds) shapes])]))

; TODO no longer used...
(def rotatedRect (\\(fill x y w h rot)
  (let [cx cy] [(+ x (/ w 2!)) (+ y (/ h 2!))]
  (let bounds [x y (+ x w) (+ y h)]
  (let shape (rotateAround rot cx cy (rect fill x y w h))
  (group bounds [shape])
)))))

(def rectangle (\\(fill stroke strokeWidth rot bounds)
  (let [left top right bot] bounds
  (let [cx cy] [(+ left (/ (- right left) 2!)) (+ top (/ (- bot top) 2!))]
  (let shape (rotateAround rot cx cy (box bounds fill stroke strokeWidth))
  shape
)))))
  ; (group bounds [shape])

; TODO no longer used...
(def rotatedEllipse (\\(fill cx cy rx ry rot)
  (let bounds [(- cx rx) (- cy ry) (+ cx rx) (+ cy ry)]
  (let shape (rotateAround rot cx cy (ellipse fill cx cy rx ry))
  (group bounds [shape])
))))

; TODO take rot
(def oval (\\(fill stroke strokeWidth bounds)
  (let [left top right bot] bounds
  (let shape
    ['OVAL'
       [ ['LEFT' left] ['TOP' top] ['RIGHT' right] ['BOT' bot]
         ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth] ]
       []]
  shape
))))

; ; TODO take rot
; (def oval (\\(fill stroke strokeWidth bounds)
;   (let [left top right bot] bounds
;   (let [rx ry] [(/ (- right left) 2!) (/ (- bot top) 2!)]
;   (let [cx cy] [(+ left rx) (+ top ry)]
;   (let shape ; TODO change def ellipse to take stroke/strokeWidth
;     ['ellipse'
;        [ ['cx' cx] ['cy' cy] ['rx' rx] ['ry' ry]
;          ['fill' fill] ['stroke' stroke] ['stroke-width' strokeWidth] ]
;        []]
;   (group bounds [shape])
; ))))))

(def scaleBetween (\\(a b pct)
  (case pct
    (0 a)
    (1 b)
    (_ (+ a (* pct (- b a)))))))

(def stretchyPolygon (\\(bounds fill stroke strokeWidth percentages)
  (let [left top right bot] bounds
  (let [xScale yScale] [(scaleBetween left right) (scaleBetween top bot)]
  (let pts (map (\\[xPct yPct] [ (xScale xPct) (yScale yPct) ]) percentages)
  (group bounds [(polygon fill stroke strokeWidth pts)])
)))))

; TODO no longer used...
(def pointyPath (\\(fill stroke w d)
  (let dot (\\(x y) (ghost (circle 'orange' x y 5)))
  (letrec pointsOf (\\cmds
    (case cmds
      ([]                     [])
      (['Z']                  [])
      (['M' x y | rest]       (append [(dot x y)] (pointsOf rest)))
      (['L' x y | rest]       (append [(dot x y)] (pointsOf rest)))
      (['Q' x1 y1 x y | rest] (append [(dot x1 y1) (dot x y)] (pointsOf rest)))
      (['C' x1 y1 x2 y2 x y | rest] (append [(dot x1 y1) (dot x2 y2) (dot x y)] (pointsOf rest)))
      (_                      'ERROR')))
  ['g' []
    (cons
      (path fill stroke w d)
      [])]
))))
      ; turning off points for now
      ; (pointsOf d)) ]

; can refactor to make one pass
; can also change representation/template code to pair points
(def stretchyPath (\\(bounds fill stroke w d)
  (let [left top right bot] bounds
  (let [xScale yScale] [(scaleBetween left right) (scaleBetween top bot)]
  (let dot (\\(x y) (ghost (circle 'orange' x y 5)))
  (letrec toPath (\\cmds
    (case cmds
      ([]    [])
      (['Z'] ['Z'])
      (['M' x y | rest] (append ['M' (xScale x) (yScale y)] (toPath rest)))
      (['L' x y | rest] (append ['L' (xScale x) (yScale y)] (toPath rest)))
      (['Q' x1 y1 x y | rest]
        (append ['Q' (xScale x1) (yScale y1) (xScale x) (yScale y)]
                (toPath rest)))
      (['C' x1 y1 x2 y2 x y | rest]
        (append ['C' (xScale x1) (yScale y1) (xScale x2) (yScale y2) (xScale x) (yScale y)]
                (toPath rest)))
      (_ 'ERROR')))
  (letrec pointsOf (\\cmds
    (case cmds
      ([]    [])
      (['Z'] [])
      (['M' x y | rest] (append [(dot (xScale x) (yScale y))] (pointsOf rest)))
      (['L' x y | rest] (append [(dot (xScale x) (yScale y))] (pointsOf rest)))
      (['Q' x1 y1 x y | rest]
        (append [(dot (xScale x1) (yScale y1)) (dot (xScale x) (yScale y))]
                (pointsOf rest)))
      (['C' x1 y1 x2 y2 x y | rest]
        (append [(dot (xScale x1) (yScale y1))
                 (dot (xScale x2) (yScale y2))
                 (dot (xScale x)  (yScale y))]
                (pointsOf rest)))
      (_ 'ERROR')))
  (group bounds
    (cons
      (path fill stroke w (toPath d))
      []))
)))))))
      ; turning off points for now
      ; (pointsOf d)))

(def evalOffset (\\[base off]
  (case off
    (0 base)
    (_ (+ base off)))))

(def stickyPolygon (\\(bounds fill stroke strokeWidth offsets)
  (let pts (map (\\[xOff yOff] [ (evalOffset xOff) (evalOffset yOff) ]) offsets)
  (group bounds [(polygon fill stroke strokeWidth pts)])
)))

; expects (f bounds) to be multiple SVGs
(def with (\\(bounds f) (f bounds)))

  ; (def with (\\(bounds f) [(group bounds (f bounds))]))

(def star (\\bounds
  (let [left top right bot] bounds
  (let [width height] [(- right left) (- bot top)]
  (let [cx cy] [(+ left (/ width 2)) (+ top (/ height 2))]
  [(nStar 'lightblue' 'black' 0 6 (min (/ width 2) (/ height 2)) 10 0 cx cy)]
)))))

(def blobs (\\blobs
  (let modifyBlob (\\[i blob]
    (case blob
      ([['g' gAttrs [shape | shapes]]]
       [['g' gAttrs [(consAttr shape ['BLOB' (toString (+ i 1))]) | shapes]]])
      ([shape] [(consAttr shape ['BLOB' (toString (+ i 1))])])
      (_       blob)))
  (svg (concat (mapi modifyBlob blobs)))
)))

; 0
['svg' [] []]

"


src = prelude
