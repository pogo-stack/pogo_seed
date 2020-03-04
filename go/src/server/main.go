package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/sha512"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"path"
	"strings"
	"time"

	pogodebugger "github.com/evgenyk/pogo_debugger"
	pq "github.com/lib/pq" //so we could connect to postgres
)

var dbConnectionString = fmt.Sprintf("host=%v user=%v dbname=%v sslmode=disable search_path=public", os.Getenv("PSQL_HOST"), os.Getenv("PSQL_USER"), os.Getenv("PSQL_DB"))
var assetsBaseDirectory string
var isServeEmbeddedResources bool
var currentExecutableHash = appChecksum()
var environmentPassthrough []byte

type pogoFile struct {
	TagName      string `json:"tag_name"`
	FileName     string `json:"file_name"`
	FileContents []byte `json:"file_contents"`
	MimeType     string `json:"mime_type"`
}

func tryServeRootAsset(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path == "/" {
		return false
	}
	requestedFullPath := fmt.Sprintf("/dist_root%v", r.URL.Path)
	requestedPathSplits := strings.Split(strings.Trim(requestedFullPath, "/"), "/")
	requestedPath := ""

	splitCount := len(requestedPathSplits)
	if splitCount > 0 {
		requestedPath = requestedPathSplits[len(requestedPathSplits)-1]
	}

	var file io.Reader
	requestedPath = path.Join(assetsBaseDirectory, requestedFullPath[1:])
	ff, err := os.Open(requestedPath)

	if err != nil {
		return false
	}

	defer ff.Close()
	file = ff

	fmt.Printf("%v \t [root asset] \t %v\n", time.Now().Local().Format(time.Stamp), requestedFullPath)
	responseMime := mime.TypeByExtension(path.Ext(requestedPath))
	serveFile(file, responseMime, w, r)
	return true
}

func serveAsset(w http.ResponseWriter, r *http.Request) {
	requestedFullPath := r.URL.Path
	requestedPathSplits := strings.Split(strings.Trim(requestedFullPath, "/"), "/")
	requestedPath := ""

	splitCount := len(requestedPathSplits)
	if splitCount > 0 {
		requestedPath = requestedPathSplits[len(requestedPathSplits)-1]
	}

	if !strings.HasPrefix(requestedFullPath, "/dist") {
		return
	}

	var file io.Reader

	requestedPath = path.Join(assetsBaseDirectory, requestedFullPath[1:])
	ff, err := os.Open(requestedPath)

	if err != nil {
		w.WriteHeader(500)
		return
	}

	defer ff.Close()
	file = ff

	fmt.Printf("%v \t [asset] \t %v\n", time.Now().Local().Format(time.Stamp), requestedFullPath)

	responseMime := mime.TypeByExtension(path.Ext(requestedPath))
	serveFile(file, responseMime, w, r)

}

func serveFile(file io.Reader, fileMime string, w http.ResponseWriter, r *http.Request) {

	bytes, _ := ioutil.ReadAll(file)

	sha512 := sha512.New()
	sha512.Write(bytes)
	theHash := `"` + fmt.Sprintf("%x", sha512.Sum(nil)) + `"`

	if theHash == r.Header.Get("If-None-Match") {
		w.WriteHeader(304) /* not modified */
		return
	}

	w.Header().Set("ETag", theHash)

	if fileMime != "" {
		w.Header().Set("Content-Type", fileMime)
	}

	w.WriteHeader(200)
	fmt.Fprint(w, string(bytes))

}

func parseRequest(r *http.Request) (rp map[string]string, rq map[string]string, rh map[string]string, rf []*pogoFile) {

	r.ParseMultipartForm(32 << 10)

	var requestParameters = map[string]string{}
	var requestCookies = map[string]string{}
	var requestHeaders = map[string]string{}
	var files = make([]*pogoFile, 0)

	if r.MultipartForm != nil {
		for headerName, fileHeaders := range r.MultipartForm.File {
			for _, header := range fileHeaders {

				f, _ := header.Open()
				defer f.Close()

				var buffer bytes.Buffer
				buffer.ReadFrom(f)
				fileMimeType := mime.TypeByExtension(path.Ext(header.Filename))
				files = append(files, &pogoFile{
					TagName:      headerName,
					FileName:     header.Filename,
					FileContents: buffer.Bytes(),
					MimeType:     fileMimeType,
				})
			}
		}
	}

	if acceptHeader, ok := r.Header["Accept"]; ok {
		accepts := strings.Split(acceptHeader[0], ",")
		requestHeaders["Accept"] = accepts[0]
	}

	if acceptHeader, ok := r.Header["X-Requested-With"]; ok {
		requestedWith := strings.Split(acceptHeader[0], ",")
		requestHeaders["X-Requested-With"] = requestedWith[0]
	}

	for formParameter, parameterValue := range r.Form {
		requestParameters[formParameter] = parameterValue[0]
	}

	for _, cookie := range r.Cookies() {
		requestCookies[cookie.Name] = cookie.Value
	}

	return requestParameters, requestCookies, requestHeaders, files
}

var db *sql.DB

func callPSP2(domainName string, requestPath string, requestParameters map[string]string, requestCookies map[string]string, requestHeaders map[string]string, files []*pogoFile) (httpCode int, responseContent []byte, responseSidecar []byte) {

	start := time.Now()

	pogodebugger.SetPogoBreakpoints(db)

	marshalledRequestParameters, _ := json.Marshal(requestParameters)
	marshalledCookies, _ := json.Marshal(requestCookies)
	marshalledHeaders, _ := json.Marshal(requestHeaders)
	if files == nil {
		files = make([]*pogoFile, 0)
	}
	pgFiles, _ := json.Marshal(files)

	err := db.QueryRow(`select http_code, response_content, additional 
						from f_pogo_entry_point(domain := $1, path := $2, request := $3, cookies := $4, headers := $5, files := $6, environment := $7)`,
		domainName, strings.TrimPrefix(requestPath, "/"), marshalledRequestParameters, marshalledCookies, marshalledHeaders, pgFiles, environmentPassthrough).Scan(&httpCode, &responseContent, &responseSidecar)

	elapsed := time.Since(start)
	fmt.Printf("%v \t [psp2] \t %v \t %v \t %v \t %s \n", time.Now().Local().Format(time.Stamp), domainName, strings.TrimPrefix(requestPath, "/"), string(marshalledRequestParameters), elapsed)

	if err != nil {
		fmt.Printf("Error: %v", err)
	}

	return httpCode, responseContent, responseSidecar

}

func handlePSPResponse(w http.ResponseWriter, r *http.Request, httpCode int, responseContent []byte, responseSidecar []byte) {
	type cookie struct {
		Value   string `json:"value"`
		Expires string `json:"expires"`
	}

	type additoinal struct {
		Headers     map[string]string
		Cookies     map[string]cookie
		ContentType string `json:"content_type"`
	}

	j := additoinal{}
	json.Unmarshal(responseSidecar, &j)

	for headerName, headerValue := range j.Headers {
		w.Header().Set(headerName, headerValue)
	}

	for cookieName, cookieParams := range j.Cookies {
		cookieExpirityTime, err := time.Parse(time.RFC3339, cookieParams.Expires)

		if err != nil {
			fmt.Printf("Error parsing date in a cookie, should be in RFC3339 %v", err)
		}

		cookie := http.Cookie{
			Name:    cookieName,
			Value:   cookieParams.Value,
			Expires: cookieExpirityTime,
			Path:    "/",
			Domain:  fmt.Sprintf(".%v", os.Getenv("POGO_PUBLIC_DOMAIN")),
			//SameSite: http.SameSiteLaxMode,
		}
		http.SetCookie(w, &cookie)
	}

	w.Header().Set("Content-Type", j.ContentType)
	w.Header().Set("Cache-Control", "must-revalidate, no-store, no-cache, private")

	w.WriteHeader(httpCode)
	w.Write([]byte(responseContent))

}

func last(s string, b byte) int {
	i := len(s)
	for i--; i >= 0; i-- {
		if s[i] == b {
			break
		}
	}
	return i
}

func getServingDomain(r *http.Request) string {
	host := r.Host
	if last(host, ':') > 0 {
		parsedHost, _, err := net.SplitHostPort(host)

		if err != nil {
			fmt.Printf("Error parsing host from %v: %v", host, err)
		}
		host = parsedHost
	}

	return host
}

func serveHTTP(w http.ResponseWriter, r *http.Request) {

	if tryServeRootAsset(w, r) {
		return
	}

	requestParameters, requestCookies, requestHeaders, files := parseRequest(r)
	httpCode, responseContent, responseSidecar := callPSP2(getServingDomain(r), r.URL.Path, requestParameters, requestCookies, requestHeaders, files)
	handlePSPResponse(w, r, httpCode, responseContent, responseSidecar)
}

func exitOnAppHashChange() {
	for {
		time.Sleep(1000 * time.Millisecond)
		if appChecksum() != currentExecutableHash {
			fmt.Printf("Exiting as executable hash changed: was %v, now %v\n", currentExecutableHash, appChecksum())
			os.Exit(0)
		}
	}
}

func appChecksum() string {
	hasher := sha256.New()
	f, err := os.Open(os.Args[0])
	if err != nil {
		os.Exit(0)
	}

	defer f.Close()
	if _, err = io.Copy(hasher, f); err != nil {
		os.Exit(0)
	}

	return fmt.Sprintf("%x", hasher.Sum(nil))
}

func main() {

	go exitOnAppHashChange()

	adFlag := flag.String("ad", "", "A base directory for assets")
	flag.Parse()

	assetsBaseDirectory = *adFlag

	fmt.Printf("Pogo server:%v:%v:%v \n", os.Getenv("PSQL_HOST"), os.Getenv("PSQL_USER"), os.Getenv("PSQL_DB"))
	fmt.Printf("Listening address %v \n", os.Getenv("POGO_LISTEN_ADDRESS"))

	if len(assetsBaseDirectory) > 0 {
		fmt.Printf("Will be serving assets and configuration from %v\n", assetsBaseDirectory)
	} else {
		fmt.Println("Will be serving assets and configuration from embedded resources")
		isServeEmbeddedResources = true
	}

	var vh = map[string]string{}

	for _, element := range os.Environ() {
		variable := strings.Split(element, "=")
		envname := variable[0]

		if strings.HasPrefix(envname, "POGO_") {
			vh[envname] = os.Getenv(variable[0])
		}
	}

	var err error
	environmentPassthrough, err = json.Marshal(vh)
	if err != nil {
		fmt.Printf("error marshalling environment passthrough %v\n", err.Error())
	}

	funcStartPogoDebugger := func() {
		pogodebugger.StartPogoDebugger(dbConnectionString, 4250)
	}

	if os.Getenv("POGO_FLAG_DEBUG") != "" {
		go funcStartPogoDebugger()
	}

	base, err := pq.NewConnector(dbConnectionString)
	if err != nil {
		log.Fatal(err)
	}

	isEnableNotices := os.Getenv("POGO_SERVER_NOTICES") != ""

	connector := pq.ConnectorWithNoticeHandler(base, func(notice *pq.Error) {
		if isEnableNotices {
			fmt.Printf("\x1b[2mServer notice: %v\x1b[0m\n", notice.Message)
		}
	})
	db = sql.OpenDB(connector)
	defer db.Close()

	http.HandleFunc("/dist/", serveAsset)
	http.HandleFunc("/", serveHTTP)
	if err := http.ListenAndServe(os.Getenv("POGO_LISTEN_ADDRESS"), nil); err != nil {
		panic(err)
	}

}
