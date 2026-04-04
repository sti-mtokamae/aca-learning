(ns com.example.acahello.hello-service
  (:import
   (java.time LocalDateTime)
   (java.util LinkedHashMap)))

(defn- ordered-map
  [& kvs]
  (let [m (LinkedHashMap.)]
    (doseq [[k v] (partition 2 kvs)]
      (.put m k v))
    m))

(defn hello-payload []
  (ordered-map
   "message" "Hello from ACA Learning via Clojure control!"
   "timestamp" (str (LocalDateTime/now))
   "service" "spring-clojure-hybrid-api"
   "version" "1.0.0"))

(defn hello-name-payload [name]
  (ordered-map
   "message" (str "Hello " name " from Clojure on Spring Boot!")
   "timestamp" (str (LocalDateTime/now))
   "service" "spring-clojure-hybrid-api"))

(defn status-payload []
  (ordered-map
   "status" "UP"
   "control" "clojure"
   "base" "spring-boot"
   "timestamp" (str (LocalDateTime/now))))