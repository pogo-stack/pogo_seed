package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	pogodebugger "github.com/evgenyk/pogo/pogo_debugger"
	_ "github.com/lib/pq"
)

func sayHello(w http.ResponseWriter, r *http.Request) {

	cookie, _ := r.Cookie("session_id")
	if cookie != nil {
		cookie_value := cookie.Value
		fmt.Printf("%v", cookie_value)
	}

	db, err := sql.Open("postgres", "host=localhost user=pogo3_user dbname=db_pogo3 sslmode=disable")

	if err != nil {
		log.Fatal(err)
	}

	httpCode := 0
	var responseContent []byte

	dat := map[string]string{}

	r.ParseMultipartForm(32 << 10)

	fmt.Printf("Form: %v\n", r.Form)

	for form_parameter, parameter_value := range r.Form {
		dat[form_parameter] = parameter_value[0]
	}

	marshalled, _ := json.Marshal(dat)

	defer db.Close()
	pogodebugger.SetPogoBreakpoints(db)
	err = db.QueryRow("select http_code, response_content from __pogo_entry_point(path := $1, request := $2)", strings.TrimPrefix(r.URL.Path, "/"), marshalled).Scan(&httpCode, &responseContent)
	//for lambda it's better to have config and auth in the database
	if err != nil {
		fmt.Printf("Error: %v", err)
	}

	message := fmt.Sprintf("%v", string(responseContent))
	w.WriteHeader(httpCode)
	w.Write([]byte(message))
}

func main() {

	funcStartPogoDebugger := func() {
		pogodebugger.StartPogoDebugger("host=localhost user=pogo3_user dbname=db_pogo3 sslmode=disable", 4250)
	}

	go funcStartPogoDebugger()

	// srv.OnNewThreadFunc = func(db *sql.DB) {
	// 	if is_debuggable {
	// 	}
	// }

	http.HandleFunc("/", sayHello)
	if err := http.ListenAndServe(":8080", nil); err != nil {
		panic(err)
	}

}
