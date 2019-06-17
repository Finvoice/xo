// XODB is the common interface for database operations that can be used with
// types from schema '{{ schema .Schema }}'.
//
// This should work with database/sql.DB and database/sql.Tx.
type XODB interface {
	Exec(string, ...interface{}) (sql.Result, error)
	Query(string, ...interface{}) (*sql.Rows, error)
	QueryRow(string, ...interface{}) *sql.Row
}

type XOTX interface {
  XODB
  Commit() error
  Rollback() error
}

// XOLog provides the log func used by generated queries.
var XOLog = func(s string, a ...interface{}) { fmt.Println(append([]interface{}{s}, a...)...) }

// Helper function for doing transactions
func DoTransaction(tx XOTX, txFunc func(XOTX) error) (err error) {
  defer func() {
    if p := recover(); p != nil {
      tx.Rollback()
      panic(p) // re-throw panic after Rollback
    } else if err != nil {
      tx.Rollback() // err is non-nil; don't change it
    } else {
      err = tx.Commit() // err is nil; if Commit returns error update err
    }
  }()

  err = txFunc(tx)
  return err
}

// Helper functions for Nullable sql values

func ToNullString(s string) sql.NullString {
  return sql.NullString{String : s, Valid : s != ""}
}

func ToNullBool(s string) sql.NullBool {
  v, err := strconv.ParseBool(s)
  return sql.NullBool{Bool : v, Valid : err == nil}
}

func ToNullInt64(i *int64) sql.NullInt64 {
  if i == nil {
    return sql.NullInt64{Int64 : 0, Valid : false }
  } else {
    return sql.NullInt64{Int64 : *i, Valid : true}
  }
}

func ToNullFloat64(f *float64) sql.NullFloat64 {
  if f == nil {
    return sql.NullFloat64{Float64 : 0, Valid : false }
  } else {
    return sql.NullFloat64{Float64 : *f, Valid : true}
  }
}

// RFC3339 = "2006-01-02T15:04:05Z00:00"
func ToNullTimeFromString(s string) mysql.NullTime {
  v, err := time.Parse(time.RFC3339, s)
  return mysql.NullTime{Time : v, Valid : err == nil}
}

func ToNullTimeFromTime(t time.Time) mysql.NullTime {
  return mysql.NullTime{Time : t, Valid : time.Time{} == t}
}

// ScannerValuer is the common interface for types that implement both the
// database/sql.Scanner and sql/driver.Valuer interfaces.
type ScannerValuer interface {
	sql.Scanner
	driver.Valuer
}

// helper function taken directly from sql/convert.go

func asString(src interface{}) string {
  switch v := src.(type) {
  case string:
    return v
  case []byte:
    return string(v)
  }
  rv := reflect.ValueOf(src)
  switch rv.Kind() {
  case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
    return strconv.FormatInt(rv.Int(), 10)
  case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
    return strconv.FormatUint(rv.Uint(), 10)
  case reflect.Float64:
    return strconv.FormatFloat(rv.Float(), 'g', -1, 64)
  case reflect.Float32:
    return strconv.FormatFloat(rv.Float(), 'g', -1, 32)
  case reflect.Bool:
    return strconv.FormatBool(rv.Bool())
  }
  return fmt.Sprintf("%v", src)
}

type XoDecimal struct {
  big.Float
}

func (xf *XoDecimal) Scan(src interface{}) error {
  if src == nil {
    *xf = XoDecimal{}
    return nil
  }
  str := asString(src)
  newxf, _, err := big.ParseFloat(str, 10, 53, big.ToNearestEven)
  *xf = XoDecimal{*newxf}
  return err
}

func (ss *XoDecimal) Value() (driver.Value, error) {
  return ss.String(), nil
}

type NullableXoDecimal struct {
  XoDecimal
  Valid bool
}

func (xf *NullableXoDecimal) Scan(src interface{}) error {
  if src == nil {
    xf.XoDecimal = XoDecimal{}
    xf.Valid = false
    return nil
  }

  return (&xf.XoDecimal).Scan(src)
}

func (ss *NullableXoDecimal) Value() (driver.Value, error) {
  if ss.Valid == false {
    return nil, nil
  }

  return ss.XoDecimal.String(), nil
}


// StringSlice is a slice of strings.
type StringSlice []string

// quoteEscapeRegex is the regex to match escaped characters in a string.
var quoteEscapeRegex = regexp.MustCompile(`([^\\]([\\]{2})*)\\"`)

// Scan satisfies the sql.Scanner interface for StringSlice.
func (ss *StringSlice) Scan(src interface{}) error {
	buf, ok := src.([]byte)
	if !ok {
		return errors.New("invalid StringSlice")
	}

	// change quote escapes for csv parser
	str := quoteEscapeRegex.ReplaceAllString(string(buf), `$1""`)
	str = strings.Replace(str, `\\`, `\`, -1)

	// remove braces
	str = str[1:len(str)-1]

	// bail if only one
	if len(str) == 0 {
		*ss = StringSlice([]string{})
		return nil
	}

	// parse with csv reader
	cr := csv.NewReader(strings.NewReader(str))
	slice, err := cr.Read()
	if err != nil {
		fmt.Printf("exiting!: %v\n", err)
		return err
	}

	*ss = StringSlice(slice)

	return nil
}

// Value satisfies the driver.Valuer interface for StringSlice.
func (ss StringSlice) Value() (driver.Value, error) {
	v := make([]string, len(ss))
	for i, s := range ss {
		v[i] = `"` + strings.Replace(strings.Replace(s, `\`, `\\\`, -1), `"`, `\"`, -1) + `"`
	}
	return "{" + strings.Join(v, ",") + "}", nil
}

// Slice is a slice of ScannerValuers.
type Slice []ScannerValuer

